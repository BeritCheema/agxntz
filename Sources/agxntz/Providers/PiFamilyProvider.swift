import Foundation

/// pi (badlogic / earendil-works) and its forks like Oh My Pi (omp):
/// tree-structured JSONL sessions grouped by dash-encoded cwd, with
/// `{"type":"session", cwd, timestamp}` metadata and `{"type":"message",
/// "message":{role, content:[{type:"text"|toolCall...}]}}` records.
struct PiFamilyProvider: AgentProvider {
    let kind: AgentKind
    let sessionsDir: URL

    static func pi() -> PiFamilyProvider {
        let dir = ProcessInfo.processInfo.environment["PI_CODING_AGENT_SESSION_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileUtil.home.appendingPathComponent(".pi/agent/sessions")
        return PiFamilyProvider(kind: .pi, sessionsDir: dir)
    }

    static func omp() -> PiFamilyProvider {
        PiFamilyProvider(kind: .omp, sessionsDir: FileUtil.home.appendingPathComponent(".omp/agent/sessions"))
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for groupDir in FileUtil.subdirectories(of: sessionsDir) {
            for (file, mtime) in FileUtil.recentFiles(in: groupDir, suffix: ".jsonl", now: now) {
                if let s = parse(file: file, mtime: mtime, groupDir: groupDir, now: now, processes: processes) {
                    sessions.append(s)
                }
            }
        }
        return sessions
    }

    private func parse(file: URL, mtime: Date, groupDir: URL,
                       now: Date, processes: ProcessSnapshot) -> AgentSession? {
        var cwd: String?
        var sessionID = file.deletingPathExtension().lastPathComponent
        var sessionStart: Date?
        var lastRole: String?
        var lastContentTypes = Set<String>()
        var lastToolName: String?
        var lastAssistantText: String?
        var lastUserTS: Date?

        for line in FileUtil.tailLines(of: file) {
            guard let obj = FileUtil.json(line),
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "session":
                cwd = obj["cwd"] as? String ?? cwd
                sessionID = obj["id"] as? String ?? sessionID
                sessionStart = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? sessionStart
            case "message":
                guard let message = obj["message"] as? [String: Any],
                      let role = message["role"] as? String else { continue }
                lastRole = role
                lastContentTypes = []
                if let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        guard let itemType = item["type"] as? String else { continue }
                        lastContentTypes.insert(itemType)
                        if role == "assistant", ["toolCall", "tool_call", "tool_use", "toolUse"].contains(itemType) {
                            lastToolName = item["name"] as? String ?? lastToolName
                        }
                        if role == "assistant", itemType == "text", let text = item["text"] as? String, !text.isEmpty {
                            lastAssistantText = text
                        }
                    }
                }
                if role == "user" {
                    lastUserTS = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? lastUserTS
                }
            default:
                continue
            }
        }

        // Files with no conversation yet (bare title/session records) are
        // sessions someone just opened; show nothing until there's a turn.
        guard lastRole != nil else { return nil }

        let age = now.timeIntervalSince(mtime)
        let alive = processes.isRunning(kind)
        // A trailing assistant tool call means the tool is *running* — these
        // agents don't record a distinct permission-prompt state in the
        // transcript, so a pending call is working, not waiting. (A running
        // tool can take longer than the fresh-write window, which is exactly
        // when this branch matters.)
        let toolRunning = lastRole == "assistant"
            && !lastContentTypes.isDisjoint(with: ["toolCall", "tool_call", "tool_use", "toolUse"])

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if toolRunning {
            state = alive ? .working : .done
        } else if lastRole == "assistant" {
            state = .done
        } else {
            // user / toolResult last: a turn is in flight.
            state = alive ? .working : .done
        }

        if state != .done && !alive { return nil }
        if state == .done && age > Tuning.doneRetention { return nil }

        let activity: String
        switch state {
        case .done: activity = "finished"
        case .waiting: activity = "waiting for you"
        case .working: activity = (toolRunning ? lastToolName.map { "running \($0)" } : nil) ?? "working"
        }

        let resolvedCwd = cwd ?? groupDir.lastPathComponent.replacingOccurrences(of: "-", with: "/")

        return AgentSession(
            id: "\(kind.idPrefix):\(sessionID)", kind: kind,
            projectName: resolvedCwd.projectNameFromPath, cwd: cwd,
            activity: activity, state: state,
            startedAt: lastUserTS ?? sessionStart ?? FileUtil.creationDate(of: file) ?? mtime,
            lastActivityAt: mtime,
            lastMessage: lastAssistantText?.messageSnippet,
            debugInfo: "lastRole=\(lastRole ?? "nil") toolRunning=\(toolRunning) age=\(Int(age))s alive=\(alive)"
        )
    }
}
