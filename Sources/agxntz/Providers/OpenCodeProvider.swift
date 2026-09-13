import Foundation

/// OpenCode (current versions): sessions live in a SQLite database at
/// ~/.local/share/opencode/opencode.db (WAL mode). Tables: `session`
/// (top-level when parent_id IS NULL), `message` (role + time in JSON `data`),
/// and `part` (text/tool parts, tool status in `data`).
struct OpenCodeProvider: AgentProvider {
    let kind = AgentKind.opencode
    private let dbPath = FileUtil.home
        .appendingPathComponent(".local/share/opencode/opencode.db").path

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        guard let db = SQLiteDB(readonlyPath: dbPath) else { return [] }
        let cutoffMs = String(Int((now.timeIntervalSince1970 - Tuning.scanWindow) * 1000))
        let sessionRows = db.query(
            """
            SELECT id, directory, title, time_created, time_updated
            FROM session
            WHERE parent_id IS NULL AND time_updated > ?
            ORDER BY time_updated DESC
            """,
            [cutoffMs]
        )

        var sessions: [AgentSession] = []
        for row in sessionRows {
            guard let id = row[0] else { continue }
            // A session is live only if an OpenCode process is running in its
            // directory; otherwise a closed CLI leaves stale DB rows behind.
            let alive = processes.isLive(kind, cwd: row[1])
            if let s = parse(db: db, id: id, directory: row[1], title: row[2],
                             createdMs: row[3], updatedMs: row[4], now: now, alive: alive) {
                sessions.append(s)
            }
        }
        return sessions
    }

    private func parse(db: SQLiteDB, id: String, directory: String?, title: String?,
                       createdMs: String?, updatedMs: String?,
                       now: Date, alive: Bool) -> AgentSession? {
        // Latest message in the session drives the state.
        let msgRows = db.query(
            "SELECT id, data, time_updated FROM message WHERE session_id = ? ORDER BY time_created DESC LIMIT 1",
            [id]
        )
        guard let msg = msgRows.first,
              let messageID = msg[0],
              let data = msg[1],
              let message = FileUtil.json(data) else { return nil }

        let role = message["role"] as? String
        let completed = (message["time"] as? [String: Any])?["completed"] != nil

        // Newest tool part on the latest assistant message: a running/pending
        // tool means the tool is executing (working), not awaiting approval —
        // OpenCode auto-runs within its granted permissions.
        var toolRunning = false
        var toolName: String?
        if role == "assistant" {
            let toolRows = db.query(
                """
                SELECT json_extract(data,'$.tool'), json_extract(data,'$.state.status')
                FROM part
                WHERE message_id = ? AND json_extract(data,'$.type') = 'tool'
                ORDER BY time_created DESC LIMIT 1
                """,
                [messageID]
            )
            if let tool = toolRows.first {
                toolName = tool[0]
                toolRunning = ["running", "pending"].contains(tool[1] ?? "")
            }
        }

        let lastActivity = Self.msDate(updatedMs) ?? now
        let age = now.timeIntervalSince(lastActivity)

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if role == "assistant" {
            // During live generation OpenCode streams parts, bumping the
            // timestamp, so age stays under the fresh-write window above.
            // Past it, a running tool means work in flight; otherwise the
            // turn is finished (completed) or stalled/abandoned — either way,
            // done rather than a stuck green "working".
            state = toolRunning ? (alive ? .working : .done) : .done
        } else {
            state = alive ? .working : .done // user message last: in-flight
        }

        if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }

        // Latest assistant text part, for the dropdown message line.
        var lastText: String?
        let textRows = db.query(
            """
            SELECT json_extract(data,'$.text')
            FROM part
            WHERE message_id = ? AND json_extract(data,'$.type') = 'text'
            ORDER BY time_created DESC LIMIT 1
            """,
            [messageID]
        )
        lastText = textRows.first?.first ?? nil

        let activity: String
        switch state {
        case .done: activity = "finished"
        case .waiting: activity = "waiting for you"
        case .working:
            if toolRunning, let toolName { activity = "running \(toolName)" }
            else if let title, !title.isEmpty, !title.hasPrefix("New session") { activity = title }
            else { activity = "working" }
        }

        return AgentSession(
            id: "opencode:\(id)", kind: kind,
            projectName: (directory ?? "opencode").projectNameFromPath, cwd: directory,
            activity: activity, state: state,
            startedAt: Self.msDate(createdMs) ?? lastActivity, lastActivityAt: lastActivity,
            lastMessage: lastText?.messageSnippet,
            debugInfo: "role=\(role ?? "nil") toolRunning=\(toolRunning) completed=\(completed) age=\(Int(age))s alive=\(alive)"
        )
    }

    private static func msDate(_ ms: String?) -> Date? {
        guard let ms, let value = Double(ms) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
