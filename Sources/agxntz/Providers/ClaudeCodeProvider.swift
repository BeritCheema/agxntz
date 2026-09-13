import Foundation

/// Claude Code: transcripts at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl.
/// State comes from hook events (~/.agxntz/claude-events.jsonl) when the
/// hooks are installed, with transcript-tail heuristics as fallback.
struct ClaudeCodeProvider: AgentProvider {
    let kind = AgentKind.claude
    private let projectsDir = FileUtil.home.appendingPathComponent(".claude/projects")

    struct HookEvent {
        let event: String
        let ts: Date
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        let hookEvents = Self.loadHookEvents()
        var sessions: [AgentSession] = []

        for projectDir in FileUtil.subdirectories(of: projectsDir) {
            for (file, mtime) in FileUtil.recentFiles(in: projectDir, suffix: ".jsonl", now: now) {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard let session = parse(
                    file: file, mtime: mtime, sessionID: sessionID,
                    hookEvent: hookEvents[sessionID], now: now, processes: processes
                ) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    private func parse(file: URL, mtime: Date, sessionID: String,
                       hookEvent: HookEvent?, now: Date, processes: ProcessSnapshot) -> AgentSession? {
        let lines = FileUtil.tailLines(of: file)
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

        // Session summary/index files have no conversation records.
        guard lastMeaningful != nil || hookEvent != nil else { return nil }

        // Claude Code appends bookkeeping records (bridge-session etc.) to
        // idle session files, so mtime alone overstates activity. Anchor on
        // the last real conversation record when we have its timestamp.
        var lastActivity = lastMeaningfulTS ?? mtime
        if let hook = hookEvent, hook.ts > lastActivity { lastActivity = hook.ts }
        guard now.timeIntervalSince(lastActivity) < Tuning.scanWindow else { return nil }

        // "Elapsed" means time on the current task: since the last human
        // prompt, falling back to the session's start.
        let startedAt = lastPromptTS ?? FileUtil.creationDate(of: file) ?? firstTimestamp ?? lastActivity
        let age = now.timeIntervalSince(lastActivity)
        let alive = processes.isRunning(kind)

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if let last = lastMeaningful {
            state = Self.heuristicState(lastRecord: last, age: age, alive: alive)
        } else {
            state = alive ? .waiting : .done
        }

        // Hook events are authoritative when newer than the transcript tail.
        if let hook = hookEvent, hook.ts >= lastActivity.addingTimeInterval(-2) {
            switch hook.event {
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart":
                state = age < 60 ? .working : state
            case "Notification":
                state = .waiting
            case "Stop", "SubagentStop":
                state = age < Tuning.workingWindow ? .working : .done
            case "SessionEnd":
                return nil
            default: break
            }
        }

        if state != .done && !alive { return nil }
        if state == .done && age > Tuning.doneRetention { return nil }

        let activity = Self.activity(state: state, lastAssistant: lastAssistant)
        let project = (cwd ?? file.deletingLastPathComponent().lastPathComponent).projectNameFromPath

        return AgentSession(
            id: "claude:\(sessionID)", kind: kind, projectName: project, cwd: cwd,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: lastActivity,
            lastMessage: lastAssistantText?.messageSnippet
        )
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
        let type = lastRecord["type"] as? String
        if type == "assistant" {
            // Assistant ended on a tool_use with no tool_result yet -> a
            // permission prompt is likely pending.
            if contentTypes(of: lastRecord).contains("tool_use") { return .waiting }
            return .done // finished its turn with a text reply
        }
        // Last record is user input or a tool result with no reply for a
        // while: treat short gaps as still working, long ones as waiting.
        return age < 90 ? .working : (alive ? .waiting : .done)
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

    // MARK: - Hook events

    static let eventsFile = FileUtil.home.appendingPathComponent(".agxntz/claude-events.jsonl")

    private static func loadHookEvents() -> [String: HookEvent] {
        var latest: [String: HookEvent] = [:]
        for line in FileUtil.tailLines(of: eventsFile, maxBytes: 64 * 1024) {
            guard let obj = FileUtil.json(line),
                  let event = obj["event"] as? String,
                  let sessionID = obj["sessionId"] as? String,
                  let tsString = obj["ts"] as? String,
                  let ts = ISO8601.parse(tsString) else { continue }
            if let existing = latest[sessionID], existing.ts > ts { continue }
            latest[sessionID] = HookEvent(event: event, ts: ts)
        }
        return latest
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
