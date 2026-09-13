import Foundation

/// OpenCode: session metadata at
/// ~/.local/share/opencode/storage/session/<project-hash>/ses_*.json,
/// with messages under storage/message/<session-id>/.
struct OpenCodeProvider: AgentProvider {
    let kind = AgentKind.opencode
    private let storageDir = FileUtil.home.appendingPathComponent(".local/share/opencode/storage")

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        let sessionRoot = storageDir.appendingPathComponent("session")
        for projectDir in FileUtil.subdirectories(of: sessionRoot) {
            for (file, mtime) in FileUtil.recentFiles(in: projectDir, suffix: ".json", now: now) {
                if let s = parse(file: file, metaMtime: mtime, now: now, processes: processes) {
                    sessions.append(s)
                }
            }
        }
        return sessions
    }

    private func parse(file: URL, metaMtime: Date, now: Date, processes: ProcessSnapshot) -> AgentSession? {
        guard let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionID = obj["id"] as? String else { return nil }
        // Child/subagent sessions carry parentID; only show top-level ones.
        if obj["parentID"] != nil { return nil }

        let directory = obj["directory"] as? String
        let title = obj["title"] as? String
        let time = obj["time"] as? [String: Any]
        let startedAt = (time?["created"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? metaMtime

        // The session meta file lags behind the message stream; use the
        // newest message file's mtime as the real activity signal.
        let messagesDir = storageDir.appendingPathComponent("message").appendingPathComponent(sessionID)
        let messages = FileUtil.recentFiles(in: messagesDir, suffix: ".json", now: now)
            .sorted { $0.mtime < $1.mtime }
        let lastActivity = max(metaMtime, messages.last?.mtime ?? .distantPast)

        let age = now.timeIntervalSince(lastActivity)
        let alive = processes.isRunning(kind)

        var lastRole: String?
        var lastCompleted = false
        if let lastMessage = messages.last,
           let mData = try? Data(contentsOf: lastMessage.url),
           let m = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
            lastRole = m["role"] as? String
            if let t = m["time"] as? [String: Any], t["completed"] != nil { lastCompleted = true }
        }

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if lastRole == "assistant" && lastCompleted {
            state = .done
        } else {
            state = age < 90 ? .working : (alive ? .waiting : .done)
        }

        if state != .done && !alive { return nil }
        if state == .done && age > Tuning.doneRetention { return nil }

        let activity: String
        switch state {
        case .done: activity = "finished"
        case .waiting: activity = "waiting for you"
        case .working: activity = (title?.isEmpty == false ? title! : "working")
        }

        return AgentSession(
            id: "opencode:\(sessionID)", kind: kind,
            projectName: (directory ?? "opencode").projectNameFromPath, cwd: directory,
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: lastActivity
        )
    }
}
