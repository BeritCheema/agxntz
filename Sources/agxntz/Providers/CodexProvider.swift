import Foundation

/// Codex CLI: rollouts at ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
/// First line is session_meta (cwd, id); tail records drive the state.
struct CodexProvider: AgentProvider {
    let kind = AgentKind.codex
    private let sessionsDir = FileUtil.home.appendingPathComponent(".codex/sessions")
    // Memoize the tail-read + JSON parse per rollout file; unchanged files are
    // re-classified cheaply each poll.
    private let cache = FileDigestCache<CodexDigest>()

    /// Everything pulled from a rollout's bytes; state/activity/age are derived
    /// from this each tick, so it's cached by mtime+size.
    struct CodexDigest {
        var cwd: String?
        var sessionID: String
        var metaTimestamp: Date?
        var parentThreadID: String?
        var nickname: String?
        var lastKind: String?
        var lastToolName: String?
        var lastMessage: String?
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var parents: [AgentSession] = []
        var subsByParent: [String: [AgentSession]] = [:]
        var seen = Set<String>()

        for yearDir in FileUtil.subdirectories(of: sessionsDir) {
            for monthDir in FileUtil.subdirectories(of: yearDir) {
                for dayDir in FileUtil.subdirectories(of: monthDir) {
                    for (file, mtime) in FileUtil.recentFiles(in: dayDir, suffix: ".jsonl", now: now) {
                        seen.insert(file.path)
                        guard let parsed = parse(file: file, mtime: mtime, now: now, processes: processes) else { continue }
                        if let parentID = parsed.parentThreadID {
                            subsByParent[parentID, default: []].append(parsed.session)
                        } else {
                            parents.append(parsed.session)
                        }
                    }
                }
            }
        }
        cache.prune(keeping: seen)

        // Attach each sub-agent to its parent session; keep orphans (parent no
        // longer present) as top-level so they aren't lost.
        var result: [AgentSession] = []
        for var parent in parents {
            let parentThreadID = parent.id.replacingOccurrences(of: "codex:", with: "")
            if let subs = subsByParent.removeValue(forKey: parentThreadID) {
                // Stable order: by state, then start time (unchanging).
                parent.subAgents = subs.sorted {
                    $0.state == $1.state ? $0.startedAt < $1.startedAt : $0.state < $1.state
                }
            }
            result.append(parent)
        }
        for orphan in subsByParent.values.flatMap({ $0 }) {
            result.append(orphan)
        }
        return result
    }

    private struct ParsedSession {
        let session: AgentSession
        let parentThreadID: String?
    }

    /// Reads a rollout's first (session_meta) line and tail once. Pure over the
    /// file bytes, so its result is cached by mtime+size.
    private static func extract(file: URL) -> CodexDigest? {
        guard let firstLine = FileUtil.firstLine(of: file),
              let meta = FileUtil.json(firstLine),
              (meta["type"] as? String) == "session_meta" else { return nil }
        let payload = meta["payload"] as? [String: Any] ?? [:]

        var d = CodexDigest(sessionID: payload["id"] as? String ?? file.deletingPathExtension().lastPathComponent)
        d.cwd = payload["cwd"] as? String
        d.metaTimestamp = (meta["timestamp"] as? String).flatMap(ISO8601.parse)

        // A sub-agent rollout carries its parent thread id and a nickname in
        // source.subagent.thread_spawn (also mirrored as top-level parent_thread_id).
        d.parentThreadID = payload["parent_thread_id"] as? String
            ?? ((((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String)
        d.nickname = (((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["agent_nickname"] as? String

        // State + a nearby message come from a small tail (cheap, common case).
        for line in FileUtil.tailLines(of: file).reversed() {
            if d.lastKind != nil && d.lastMessage != nil { break }
            guard let obj = FileUtil.json(line),
                  let type = obj["type"] as? String else { continue }
            guard type == "response_item" || type == "event_msg" else { continue }
            guard let p = obj["payload"] as? [String: Any],
                  let pType = p["type"] as? String else { continue }
            if type == "event_msg" {
                // Newer Codex writes explicit turn lifecycle events; they are
                // the most reliable signal when they trail the transcript.
                if pType == "task_complete" || pType == "turn_aborted" {
                    if d.lastKind == nil { d.lastKind = "task_complete" }
                    if d.lastMessage == nil { d.lastMessage = p["last_agent_message"] as? String }
                }
                if pType == "task_started", d.lastKind == nil { d.lastKind = "task_started" }
                continue
            }
            switch pType {
            case "message":
                let isAssistant = (p["role"] as? String) == "assistant"
                if d.lastKind == nil { d.lastKind = isAssistant ? "message" : "user" }
                if isAssistant, d.lastMessage == nil { d.lastMessage = Self.assistantText(p) }
            case "function_call", "local_shell_call", "custom_tool_call":
                if d.lastKind == nil {
                    d.lastKind = "function_call"
                    d.lastToolName = p["name"] as? String
                }
            case "function_call_output", "local_shell_call_output", "custom_tool_call_output":
                if d.lastKind == nil { d.lastKind = "function_call_output" }
            case "reasoning":
                if d.lastKind == nil { d.lastKind = "reasoning" }
            default:
                continue
            }
        }

        // A working sub-agent that's been reasoning produces no message in the
        // small tail — Codex's ~300KB encrypted reasoning blobs push the last
        // assistant message ~1MB back. Fetch just that one line by byte-search,
        // so the giant blobs in between are never decoded or parsed.
        if d.lastMessage == nil,
           let line = FileUtil.lastLineContaining("output_text", in: file, maxBytes: 3 * 1024 * 1024),
           let obj = FileUtil.json(line),
           let p = obj["payload"] as? [String: Any],
           (p["role"] as? String) == "assistant" {
            d.lastMessage = Self.assistantText(p)
        }
        return d
    }

    /// Joined text of an assistant `message` payload's output_text/text items.
    private static func assistantText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            ["output_text", "text"].contains(item["type"] as? String ?? "") ? item["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private func parse(file: URL, mtime: Date, now: Date, processes: ProcessSnapshot) -> ParsedSession? {
        guard let digest = cache.value(for: file, mtime: mtime, produce: {
            Self.extract(file: file)
        }) else { return nil }

        let cwd = digest.cwd
        let sessionID = digest.sessionID
        let startedAt = digest.metaTimestamp ?? mtime
        let parentThreadID = digest.parentThreadID
        let nickname = digest.nickname
        let lastKind = digest.lastKind
        let lastToolName = digest.lastToolName
        let lastMessage = digest.lastMessage

        let age = now.timeIntervalSince(mtime)
        let alive = processes.isLive(kind, cwd: cwd, transcriptPath: file.path)

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if lastKind == "task_complete" {
            // Only an explicit task_complete/turn_aborted marks a turn done.
            state = .done
        } else {
            // Everything else is a turn still in flight: an assistant `message`
            // is often a mid-turn progress update (Codex keeps reasoning and
            // running tools after it), reasoning/task_started are pre-output,
            // and a pending function_call is an auto-run tool executing. All
            // are working while the process is alive.
            state = alive ? .working : .done
        }

        if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }

        var activity: String
        switch state {
        case .done: activity = "finished"
        case .waiting: activity = lastToolName.map { "wants to run \($0)" } ?? "waiting for you"
        case .working:
            switch lastKind {
            case "reasoning": activity = "thinking"
            case "function_call":
                switch lastToolName {
                case "wait": activity = "running background task"
                case "exec", "shell", "local_shell", "bash", nil: activity = "running a command"
                case let name?: activity = "running \(name)"
                }
            case "message": activity = "responding"
            default: activity = "working"
            }
        }

        // Sub-agents are labeled by nickname; a sub-agent's id is namespaced
        // so it can be pinned/resolved distinctly from top-level sessions.
        let isSub = parentThreadID != nil
        let idPrefix = isSub ? "codex-sub" : "codex"
        let project = nickname ?? (cwd ?? "codex").projectNameFromPath

        let session = AgentSession(
            id: "\(idPrefix):\(sessionID)", kind: kind,
            projectName: project, cwd: cwd,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: mtime,
            lastMessage: lastMessage?.messageSnippet,
            debugInfo: "lastKind=\(lastKind ?? "nil") age=\(Int(age))s alive=\(alive)\(isSub ? " sub" : "")"
        )
        return ParsedSession(session: session, parentThreadID: parentThreadID)
    }
}
