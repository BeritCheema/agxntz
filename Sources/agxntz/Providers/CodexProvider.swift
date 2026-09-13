import Foundation

/// Codex CLI: rollouts at ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
/// First line is session_meta (cwd, id); tail records drive the state.
struct CodexProvider: AgentProvider {
    let kind = AgentKind.codex
    private let sessionsDir = FileUtil.home.appendingPathComponent(".codex/sessions")

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for yearDir in FileUtil.subdirectories(of: sessionsDir) {
            for monthDir in FileUtil.subdirectories(of: yearDir) {
                for dayDir in FileUtil.subdirectories(of: monthDir) {
                    for (file, mtime) in FileUtil.recentFiles(in: dayDir, suffix: ".jsonl", now: now) {
                        if let s = parse(file: file, mtime: mtime, now: now, processes: processes) {
                            sessions.append(s)
                        }
                    }
                }
            }
        }
        return sessions
    }

    private func parse(file: URL, mtime: Date, now: Date, processes: ProcessSnapshot) -> AgentSession? {
        guard let firstLine = FileUtil.firstLine(of: file),
              let meta = FileUtil.json(firstLine),
              (meta["type"] as? String) == "session_meta" else { return nil }
        let payload = meta["payload"] as? [String: Any] ?? [:]
        let cwd = payload["cwd"] as? String
        let sessionID = payload["id"] as? String ?? file.deletingPathExtension().lastPathComponent
        let startedAt = (meta["timestamp"] as? String).flatMap(ISO8601.parse) ?? mtime

        var lastKind: String?     // reasoning | message | function_call | function_call_output | user
        var lastToolName: String?
        for line in FileUtil.tailLines(of: file).reversed() {
            guard let obj = FileUtil.json(line),
                  let type = obj["type"] as? String else { continue }
            guard type == "response_item" || type == "event_msg" else { continue }
            guard let p = obj["payload"] as? [String: Any],
                  let pType = p["type"] as? String else { continue }
            if type == "response_item" {
                switch pType {
                case "message":
                    lastKind = (p["role"] as? String) == "assistant" ? "message" : "user"
                case "function_call", "local_shell_call", "custom_tool_call":
                    lastKind = "function_call"
                    lastToolName = p["name"] as? String
                case "function_call_output", "local_shell_call_output", "custom_tool_call_output":
                    lastKind = "function_call_output"
                case "reasoning":
                    lastKind = "reasoning"
                default:
                    continue
                }
                break
            }
        }

        let age = now.timeIntervalSince(mtime)
        let alive = processes.isRunning(kind)

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else {
            switch lastKind {
            case "message":
                state = .done
            case "function_call":
                // A call with no recorded output after the working window
                // usually means an approval prompt is pending.
                state = alive ? .waiting : .done
            default:
                state = age < 90 ? .working : (alive ? .waiting : .done)
            }
        }

        if state != .done && !alive { return nil }
        if state == .done && age > Tuning.doneRetention { return nil }

        var activity: String
        switch state {
        case .done: activity = "finished"
        case .waiting: activity = lastToolName.map { "wants to run \($0)" } ?? "waiting for you"
        case .working:
            switch lastKind {
            case "reasoning": activity = "thinking"
            case "function_call": activity = lastToolName.map { "running \($0)" } ?? "running a tool"
            case "message": activity = "responding"
            default: activity = "working"
            }
        }

        return AgentSession(
            id: "codex:\(sessionID)", kind: kind,
            projectName: (cwd ?? "codex").projectNameFromPath, cwd: cwd,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: mtime
        )
    }
}
