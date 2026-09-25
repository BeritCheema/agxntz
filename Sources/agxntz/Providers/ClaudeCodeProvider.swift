import Foundation

/// Claude Code: transcripts at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl.
/// State is derived purely from reading the transcript tail — no hooks.
struct ClaudeCodeProvider: AgentProvider {
    let kind = AgentKind.claude
    private let projectsDir = FileUtil.home.appendingPathComponent(".claude/projects")
    // Memoize the expensive tail-read + JSON parse per file; unchanged
    // transcripts (the common idle case) are re-classified cheaply each poll.
    private let cache = FileDigestCache<ClaudeDigest>()
    private let subCache = FileDigestCache<ClaudeDigest>()

    /// Everything extracted from a transcript's bytes. State/age/activity are
    /// derived from this each tick, so this is cached until the file changes.
    struct ClaudeDigest {
        var cwd: String?
        var lastMeaningful: [String: Any]?   // nil => oversized-record fallback
        var lastMeaningfulTS: Date?
        var lastAssistant: [String: Any]?
        var lastAssistantText: String?
        var firstTimestamp: Date?
        var lastPromptTS: Date?
        var subLabel: String?                // sub-agent task label (from prompt)
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        var seen = Set<String>()
        var subSeen = Set<String>()
        for projectDir in FileUtil.subdirectories(of: projectsDir) {
            for (file, mtime) in FileUtil.recentFiles(in: projectDir, suffix: ".jsonl", now: now) {
                seen.insert(file.path)
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard let session = parse(
                    file: file, mtime: mtime, sessionID: sessionID,
                    now: now, processes: processes, subSeen: &subSeen
                ) else { continue }
                sessions.append(session)
            }
        }
        cache.prune(keeping: seen)
        subCache.prune(keeping: subSeen)
        return sessions
    }

    private func parse(file: URL, mtime: Date, sessionID: String,
                       now: Date, processes: ProcessSnapshot,
                       subSeen: inout Set<String>) -> AgentSession? {
        guard let digest = cache.value(for: file, mtime: mtime, produce: {
            Self.extract(file: file, isSub: false)
        }) else { return nil }

        let cwd = digest.cwd
        let lastMeaningful = digest.lastMeaningful
        let lastMeaningfulTS = digest.lastMeaningfulTS
        let lastAssistant = digest.lastAssistant
        let lastAssistantText = digest.lastAssistantText
        let firstTimestamp = digest.firstTimestamp
        let lastPromptTS = digest.lastPromptTS

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
        // generation. A `/compact` likewise writes a `user` record flagged
        // isCompactSummary: the compacted context sits idle awaiting the next
        // real prompt — the agent is NOT generating. Neither must trip the
        // "recent write = working" shortcut, or an idle marker (away-summary,
        // or a fresh compaction) flips a done session back to green.
        let isTurnEndMarker = (lastMeaningful["type"] as? String) == "system"
            || (lastMeaningful["isCompactSummary"] as? Bool) == true

        // A trailing AskUserQuestion is an interactive prompt blocked on the
        // user's answer — unambiguously "waiting" the instant it appears, so
        // it must bypass the "recent write = working" shortcut (otherwise the
        // question reads green for its first seconds, or longer).
        let pendingQuestion = (lastMeaningful["type"] as? String) == "assistant"
            && Self.lastToolName(lastMeaningful) == "AskUserQuestion"

        // A trailing tool_use with no result is either a tool running or a
        // permission prompt — indistinguishable in the transcript. The process
        // tells them apart: a running command has a live shell child; a prompt
        // the agent is blocked on does not.
        let pendingToolUse = (lastMeaningful["type"] as? String) == "assistant"
            && Self.contentTypes(of: lastMeaningful).contains("tool_use")
        let executing = processes.hasRunningCommand(kind, cwd: cwd)

        var state: SessionState
        if pendingQuestion {
            state = .waiting
        } else if pendingToolUse {
            state = Self.toolUseState(age: age, alive: alive, executing: executing)
        } else if age < Tuning.workingWindow && !isTurnEndMarker {
            state = .working
        } else {
            state = Self.heuristicState(lastRecord: lastMeaningful, age: age, alive: alive)
        }

        // A session isn't finished while its sub-agents are still running: the
        // parent's own transcript can end on a reply (done) or sit on the
        // Task/Agent call that spawned them (which the permission heuristic
        // would read as waiting). Either way it's really working — waiting on
        // its sub-agents, not on the user. A genuine prompt (AskUserQuestion,
        // or a permission wait on some other tool) is left as waiting.
        let subAgents = scanSubAgents(parentDir: file.deletingPathExtension(), cwd: cwd, now: now,
                                      parentAlive: alive, subSeen: &subSeen)
        let runningSubs = subAgents.filter { $0.state == .working }.count
        var activityOverride: String?
        if runningSubs > 0 {
            let delegating = pendingToolUse && ["Task", "Agent"].contains(Self.lastToolName(lastMeaningful) ?? "")
            if state == .done || (state == .waiting && delegating) {
                state = .working
                activityOverride = "waiting on \(runningSubs) subagent\(runningSubs == 1 ? "" : "s")"
            }
        }

        if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }

        let activity = activityOverride ?? Self.activity(state: state, lastAssistant: lastAssistant)
        let project = (cwd ?? Self.decodeDir(file.deletingLastPathComponent().lastPathComponent)).projectNameFromPath

        return AgentSession(
            id: "claude:\(sessionID)", kind: kind, projectName: project, cwd: cwd,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: lastActivity,
            lastMessage: lastAssistantText?.messageSnippet,
            debugInfo: "lastType=\(lastMeaningful["type"] as? String ?? "nil") age=\(Int(age))s alive=\(alive) subsRunning=\(runningSubs)",
            subAgents: subAgents
        )
    }

    /// Reads a transcript's tail once and pulls out everything state derivation
    /// needs. Pure over the file bytes, so its result is cached by mtime+size.
    private static func extract(file: URL, isSub: Bool) -> ClaudeDigest? {
        // A single record can be huge (a screenshot or big file read is one
        // JSONL line, seen up to ~800KB), so read a generous tail — a small
        // window can land entirely inside one record and yield no parseable
        // conversation line, which would drop an active session.
        let lines = FileUtil.tailLines(of: file, maxBytes: isSub ? 1024 * 1024 : 2 * 1024 * 1024)
        guard !lines.isEmpty else { return nil }

        var d = ClaudeDigest()
        for line in lines {
            guard let obj = FileUtil.json(line) else { continue }
            if !isSub, d.cwd == nil, let c = obj["cwd"] as? String { d.cwd = c }
            if d.firstTimestamp == nil, let ts = obj["timestamp"] as? String {
                d.firstTimestamp = ISO8601.parse(ts)
            }
            if !isSub, obj["isSidechain"] as? Bool == true { continue }
            guard let type = obj["type"] as? String else { continue }
            let meaningful = isSub ? (type == "user" || type == "assistant")
                                   : (type == "user" || type == "assistant" || type == "system")
            guard meaningful else { continue }
            d.lastMeaningful = obj
            d.lastMeaningfulTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? d.lastMeaningfulTS
            if type == "assistant" {
                d.lastAssistant = obj
                if let text = assistantText(obj) { d.lastAssistantText = text }
            }
            if type == "user" {
                if !isSub, isHumanPrompt(obj) {
                    d.lastPromptTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? d.lastPromptTS
                }
                // A sub-agent's first user message is its task prompt -> label.
                if isSub, d.subLabel == nil, let prompt = userText(obj) { d.subLabel = prompt }
            }
        }
        return d
    }

    /// Sub-agents live in <projectDir>/<sessionID>/subagents/agent-<id>.jsonl,
    /// one file per sub-agent, each a full sidechain transcript.
    private func scanSubAgents(parentDir: URL, cwd: String?, now: Date, parentAlive: Bool, subSeen: inout Set<String>) -> [AgentSession] {
        let dir = parentDir.appendingPathComponent("subagents")
        var out: [AgentSession] = []
        for (file, mtime) in FileUtil.recentFiles(in: dir, suffix: ".jsonl", now: now) {
            subSeen.insert(file.path)
            if let sub = parseSubAgent(file: file, mtime: mtime, cwd: cwd, now: now, parentAlive: parentAlive) {
                out.append(sub)
            }
        }
        // Newest activity first.
        // Stable order: by state, then start time (start time never changes,
        // so nested rows don't reshuffle as activity ticks).
        return out.sorted { $0.state == $1.state ? $0.startedAt < $1.startedAt : $0.state < $1.state }
    }

    private func parseSubAgent(file: URL, mtime: Date, cwd: String?, now: Date, parentAlive: Bool) -> AgentSession? {
        guard let digest = subCache.value(for: file, mtime: mtime, produce: {
            Self.extract(file: file, isSub: true)
        }), let lastMeaningful = digest.lastMeaningful else { return nil }

        let lastMeaningfulTS = digest.lastMeaningfulTS
        let lastAssistant = digest.lastAssistant
        let lastAssistantText = digest.lastAssistantText
        let label = digest.subLabel
        let firstTS = digest.firstTimestamp

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

    /// A pending tool call's state, told apart by process signal: a running
    /// command has a live shell child (working); a permission prompt the agent
    /// is blocked on does not (waiting). A brief start grace covers the moment
    /// before the shell spawns so a real run doesn't flash orange.
    private static func toolUseState(age: TimeInterval, alive: Bool, executing: Bool) -> SessionState {
        if !alive { return .done }                          // process gone mid-tool
        if executing { return .working }                    // command actively running
        if age < Tuning.toolStartGrace { return .working }  // shell may still be spawning
        return .waiting                                     // idle -> blocked on you
    }

    private static func heuristicState(lastRecord: [String: Any], age: TimeInterval, alive: Bool) -> SessionState {
        // A `/compact` summary is an idle turn-end marker (see parse): the
        // conversation is compacted and waiting for the user, not generating.
        if (lastRecord["isCompactSummary"] as? Bool) == true { return .done }
        switch lastRecord["type"] as? String {
        case "assistant":
            // Assistant ended on a tool_use with no tool_result yet. Pending
            // tool calls are routed through toolUseState in parse (process
            // signal), so this fallback only covers unusual cases: keep it
            // conservative and treat it as a running tool.
            if contentTypes(of: lastRecord).contains("tool_use") {
                return alive ? .working : .done
            }
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

    /// Name of the last tool_use in a record's content, if any.
    private static func lastToolName(_ record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        return content.last { $0["type"] as? String == "tool_use" }?["name"] as? String
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
            // Interactive question: show the question itself, not an approval prompt.
            if name == "AskUserQuestion" {
                if let questions = input["questions"] as? [[String: Any]],
                   let q = questions.first?["question"] as? String, !q.isEmpty {
                    return q
                }
                return "asking you a question"
            }
            let described = describeTool(name: name, input: input)
            // Descriptions are mostly gerunds ("editing X"), so prefix with a
            // label rather than "wants to …" (which read "wants to editing X").
            return state == .waiting ? "needs approval: \(described)" : described
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

    /// Transcript timestamps are a fixed UTC form — "2026-09-14T07:15:21.712Z"
    /// (fractional seconds optional). NSISO8601DateFormatter routes every parse
    /// through ICU (locale creation, number-affix parsing) and dominated CPU at
    /// the 1s poll. This hand-rolls the common case with plain integer math and
    /// only falls back to the formatter for anything off-format.
    static func parse(_ s: String) -> Date? {
        if let d = fastParse(s) { return d }
        return withFractional.date(from: s) ?? plain.date(from: s)
    }

    private static func fastParse(_ s: String) -> Date? {
        let u = s.utf8
        guard u.count >= 20 else { return nil }
        var it = u.makeIterator()
        var buf = [UInt8](); buf.reserveCapacity(u.count)
        while let b = it.next() { buf.append(b) }
        // Positions: YYYY-MM-DDTHH:MM:SS[.fff]Z
        func digits(_ start: Int, _ n: Int) -> Int? {
            var v = 0
            for i in start..<(start + n) {
                let c = buf[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard buf[4] == 45, buf[7] == 45, buf[10] == 84 || buf[10] == 116,
              buf[13] == 58, buf[16] == 58, buf.last == 90 || buf.last == 122 else { return nil }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2)
        else { return nil }
        var frac = 0.0
        if buf.count > 20, buf[19] == 46 {  // '.'
            var i = 20, scale = 0.1
            while i < buf.count, buf[i] >= 48, buf[i] <= 57 {
                frac += Double(buf[i] - 48) * scale
                scale /= 10; i += 1
            }
        }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        guard let date = utcCalendar.date(from: c) else { return nil }
        return date.addingTimeInterval(frac)
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    static func string(from date: Date) -> String {
        withFractional.string(from: date)
    }
}
