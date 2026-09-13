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
        var lastText: String?
        // Walk messages newest-first until we find assistant text to show.
        for message in messages.reversed() {
            guard let mData = try? Data(contentsOf: message.url),
                  let m = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] else { continue }
            if lastRole == nil {
                lastRole = m["role"] as? String
                if let t = m["time"] as? [String: Any], t["completed"] != nil { lastCompleted = true }
            }
            if m["role"] as? String == "assistant" {
                let messageID = message.url.deletingPathExtension().lastPathComponent
                lastText = assistantText(messageID: messageID)
                break
            }
        }

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if lastRole == "assistant" && lastCompleted {
            state = .done
        } else {
            // Turn in flight (user message last, or assistant not yet
            // completed): working while the process lives.
            state = alive ? .working : .done
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
            activity: activity, state: state, startedAt: startedAt, lastActivityAt: lastActivity,
            lastMessage: lastText?.messageSnippet,
            debugInfo: "lastRole=\(lastRole ?? "nil") completed=\(lastCompleted) age=\(Int(age))s alive=\(alive)"
        )
    }

    /// Latest text part of a message, from storage/part/<message-id>/.
    private func assistantText(messageID: String) -> String? {
        let partsDir = storageDir.appendingPathComponent("part").appendingPathComponent(messageID)
        let parts = ((try? FileManager.default.contentsOfDirectory(atPath: partsDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
        for name in parts.reversed() {
            guard let data = try? Data(contentsOf: partsDir.appendingPathComponent(name)),
                  let part = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  part["type"] as? String == "text",
                  let text = part["text"] as? String, !text.isEmpty else { continue }
            return text
        }
        return nil
    }
}
