import Foundation

/// Claude Code: transcripts at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl.
/// State is derived purely from reading the transcript tail — no hooks.
struct ClaudeCodeProvider: AgentProvider {
    let kind = AgentKind.claude
    private let projectsDir = FileUtil.home.appendingPathComponent(".claude/projects")

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for projectDir in FileUtil.subdirectories(of: projectsDir) {
            for (file, mtime) in FileUtil.recentFiles(in: projectDir, suffix: ".jsonl", now: now) {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard let session = parse(
                    file: file, mtime: mtime, sessionID: sessionID,
                    now: now, processes: processes
                ) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    private func parse(file: URL, mtime: Date, sessionID: String,
                       now: Date, processes: ProcessSnapshot) -> AgentSession? {
        // A single record can be huge (a screenshot or big file read is one
        // JSONL line, seen up to ~800KB), so read a generous tail — a small
        // window can land entirely inside one record and yield no parseable
        // conversation line, which would drop an active session.
        let lines = FileUtil.tailLines(of: file, maxBytes: 2 * 1024 * 1024)
        guard !lines.isEmpty else { return nil }

        var cwd: String?
        var lastMeaningful: [String: Any]?
        var lastMeaningfulTS: Date?
        var lastAssistant: [String: Any]?
        var firstTimestamp: Date?
        var lastPromptTS: Date?
        var lastAssistantText: String?

        for line in lines {
            guard let obj = FileUtil.json(line) else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if firstTimestamp == nil, let ts = obj["timestamp"] as? String {
                firstTimestamp = ISO8601.parse(ts)
            }
            if obj["isSidechain"] as? Bool == true { continue }
            guard let type = obj["type"] as? String else { continue }
            if type == "user" || type == "assistant" || type == "system" {
                lastMeaningful = obj
                lastMeaningfulTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? lastMeaningfulTS
                if type == "assistant" {
                    lastAssistant = obj
                    if let text = Self.assistantText(obj) { lastAssistantText = text }
                }
                if type == "user", Self.isHumanPrompt(obj) {
                    lastPromptTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? lastPromptTS
                }
            }
        }

        let alive = processes.isLive(kind, cwd: cwd, transcriptPath: file.path)

        // Fallback: the tail was entirely one oversized record (no parseable
        // conversation line). Rather than drop what may be an active session,
        // keep it and derive state from file freshness. Only real transcripts
        // in an actively-running Claude reach here; stale ones age out below.
        guard let lastMeaningful else {
            let age = now.timeIntervalSince(mtime)
            guard age < Tuning.scanWindow else { return nil }
            let state: SessionState = age < Tuning.workingWindow
                ? .working
                : (alive ? .working : .done)
            if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }
            let project = (cwd ?? Self.decodeDir(file.deletingLastPathComponent().lastPathComponent)).projectNameFromPath
            return AgentSession(
                id: "claude:\(sessionID)", kind: kind, projectName: project, cwd: cwd,
                activity: state == .done ? "finished" : "working",
                state: state, startedAt: firstTimestamp ?? mtime, lastActivityAt: mtime,
                lastMessage: nil, debugInfo: "lastType=oversized age=\(Int(age))s alive=\(alive)"
            )
        }

        // Claude Code appends bookkeeping records (bridge-session etc.) to
        // idle session files, so mtime alone overstates activity. Anchor on
        // the last real conversation record when we have its timestamp.
        let lastActivity = lastMeaningfulTS ?? mtime
        guard now.timeIntervalSince(lastActivity) < Tuning.scanWindow else { return nil }

        // "Elapsed" means time on the current task: since the last human
        // prompt, falling back to the session's start.
        let startedAt = lastPromptTS ?? FileUtil.creationDate(of: file) ?? firstTimestamp ?? lastActivity
        let age = now.timeIntervalSince(lastActivity)

        // A standalone `system` record is only ever written at turn-end/idle
        // (stop_hook_summary, turn_duration, away_summary) — never during live
        // generation. So a freshly-written system marker must NOT trip the
        // "recent write = working" shortcut, or an idle away-summary flips a
        // long-done session back to green for a few seconds.
        let isTurnEndMarker = (lastMeaningful["type"] as? String) == "system"

        var state: SessionState
        if age < Tuning.workingWindow && !isTurnEndMarker {
            state = .working
        } else {
            state = Self.heuristicState(lastRecord: lastMeaningful, age: age, alive: alive)
        }

        if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }

        let activity = Self.activity(state: state, lastAssistant: lastAssistant)
        let project = (cwd ?? Self.decodeDir(file.deletingLastPathComponent().lastPathComponent)).projectNameFromPath

        return AgentSession(
            id: "claude:\(sessionID)", kind: kind, projectName: project, cwd: cwd,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: lastActivity,
            lastMessage: lastAssistantText?.messageSnippet,
            debugInfo: "lastType=\(lastMeaningful["type"] as? String ?? "nil") age=\(Int(age))s alive=\(alive)",
            subAgents: scanSubAgents(parentDir: file.deletingPathExtension(), cwd: cwd, now: now, parentAlive: alive)
        )
    }

    /// Sub-agents live in <projectDir>/<sessionID>/subagents/agent-<id>.jsonl,
    /// one file per sub-agent, each a full sidechain transcript.
    private func scanSubAgents(parentDir: URL, cwd: String?, now: Date, parentAlive: Bool) -> [AgentSession] {
        let dir = parentDir.appendingPathComponent("subagents")
        var out: [AgentSession] = []
        for (file, mtime) in FileUtil.recentFiles(in: dir, suffix: ".jsonl", now: now) {
            if let sub = parseSubAgent(file: file, mtime: mtime, cwd: cwd, now: now, parentAlive: parentAlive) {
                out.append(sub)
            }
        }
        // Newest activity first.
        return out.sorted { $0.state == $1.state ? $0.lastActivityAt > $1.lastActivityAt : $0.state < $1.state }
    }

    private func parseSubAgent(file: URL, mtime: Date, cwd: String?, now: Date, parentAlive: Bool) -> AgentSession? {
        let lines = FileUtil.tailLines(of: file, maxBytes: 1024 * 1024)
        guard !lines.isEmpty else { return nil }

        var lastMeaningful: [String: Any]?
        var lastMeaningfulTS: Date?
        var lastAssistant: [String: Any]?
        var lastAssistantText: String?
        var label: String?
        var firstTS: Date?

        for line in lines {
            guard let obj = FileUtil.json(line), let type = obj["type"] as? String else { continue }
            if firstTS == nil, let ts = obj["timestamp"] as? String { firstTS = ISO8601.parse(ts) }
            guard type == "user" || type == "assistant" else { continue }
            lastMeaningful = obj
            lastMeaningfulTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? lastMeaningfulTS
            if type == "assistant" {
                lastAssistant = obj
                if let text = Self.assistantText(obj) { lastAssistantText = text }
            }
            // The first user message is the task prompt — use it as the label.
            if type == "user", label == nil, let prompt = Self.userText(obj) {
                label = prompt
            }
        }
        guard let lastMeaningful else { return nil }

        let lastActivity = lastMeaningfulTS ?? mtime
        let age = now.timeIntervalSince(lastActivity)

        // Sub-agents run autonomously (no permission prompts), so a trailing
        // tool_use is a running tool -> working, not waiting.
        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if (lastMeaningful["type"] as? String) == "assistant",
                  !Self.contentTypes(of: lastMeaningful).contains("tool_use") {
            state = age >= 30 ? .done : .working
        } else {
            state = parentAlive ? .working : .done
        }

        // Sub-agents are ephemeral: keep only while running, or briefly after
        // finishing so completion is visible; drop dead ones fast.
        if !parentAlive { return nil }
        if state == .done && age > 2 * 60 { return nil }

        let agentID = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "agent-", with: "")
        let activity = Self.activity(state: state, lastAssistant: lastAssistant)

        return AgentSession(
            id: "claude-sub:\(agentID)", kind: kind,
            projectName: Self.shortLabel(label) ?? "subagent", cwd: cwd,
            activity: activity, state: state,
            startedAt: firstTS ?? lastActivity, lastActivityAt: lastActivity,
            lastMessage: lastAssistantText?.messageSnippet,
            debugInfo: "subagent age=\(Int(age))s"
        )
    }

    /// A short, single-line label from the sub-agent's task prompt.
    private static func shortLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 36 ? String(collapsed.prefix(36)) + "…" : collapsed
    }

    private static func userText(_ record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Turn Claude Code's encoded project-dir name back into a rough path so
    /// the last component reads as the project ("-Users-me-Projects-app").
    private static func decodeDir(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "/")
    }

    private static func assistantText(_ record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            item["type"] as? String == "text" ? item["text"] as? String : nil
        }
        let joined = texts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func heuristicState(lastRecord: [String: Any], age: TimeInterval, alive: Bool) -> SessionState {
        switch lastRecord["type"] as? String {
        case "assistant":
            // Assistant ended on a tool_use with no tool_result yet -> a
            // permission prompt is likely pending.
            if contentTypes(of: lastRecord).contains("tool_use") { return .waiting }
            // A trailing text reply usually means the turn ended, but it can
            // also be a mid-turn status update with the next tool call still
            // being generated — debounce before declaring the turn done.
            return age >= 30 ? .done : .working
        case "system":
            // Claude Code writes standalone system records (stop_hook_summary,
            // turn_duration, away_summary) the moment a turn finishes, so a
            // trailing system record means the turn is done.
            return .done
        default:
            // Last record is user input or a tool result: the assistant owes
            // a response. Generation (thinking, long replies) can run for
            // minutes without a transcript write, so this is WORKING no matter
            // how old the last write is — never "waiting".
            return alive ? .working : .done
        }
    }

    /// True for records representing an actual typed user prompt, as opposed
    /// to tool results echoed back under the user role.
    private static func isHumanPrompt(_ record: [String: Any]) -> Bool {
        guard let message = record["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        guard let content = message["content"] as? [[String: Any]] else { return false }
        let types = Set(content.compactMap { $0["type"] as? String })
        return types.contains("text") && !types.contains("tool_result")
    }

    private static func contentTypes(of record: [String: Any]) -> Set<String> {
        guard let message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return Set(content.compactMap { $0["type"] as? String })
    }

    private static func activity(state: SessionState, lastAssistant: [String: Any]?) -> String {
        if state == .done { return "finished" }
        guard let assistant = lastAssistant,
              let message = assistant["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return state == .waiting ? "waiting for you" : "working"
        }
        if let toolUse = content.last(where: { $0["type"] as? String == "tool_use" }),
           let name = toolUse["name"] as? String {
            let input = toolUse["input"] as? [String: Any] ?? [:]
            let described = describeTool(name: name, input: input)
            return state == .waiting ? "wants to \(described)" : described
        }
        if state == .waiting { return "waiting for you" }
        return "responding"
    }

    private static func describeTool(name: String, input: [String: Any]) -> String {
        func basename(_ key: String) -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Edit", "Write", "NotebookEdit":
            if let f = basename("file_path") { return "editing \(f)" }
            return "editing files"
        case "Read":
            if let f = basename("file_path") { return "reading \(f)" }
            return "reading files"
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty {
                return d.prefix(1).lowercased() + d.dropFirst()
            }
            return "running a command"
        case "Grep", "Glob": return "searching code"
        case "Task", "Agent": return "running subagents"
        case "WebFetch", "WebSearch": return "browsing the web"
        case "TodoWrite": return "planning"
        default: return "using \(name)"
        }
    }

}

enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        withFractional.date(from: s) ?? plain.date(from: s)
    }

    static func string(from date: Date) -> String {
        withFractional.string(from: date)
    }
}
