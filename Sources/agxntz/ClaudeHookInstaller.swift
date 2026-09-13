import Foundation

/// Installs Claude Code hooks that push precise state events to
/// ~/.agxntz/claude-events.jsonl. The hook command is a stable shim script
/// so ~/.claude/settings.json never needs to change if the app moves.
enum ClaudeHookInstaller {
    static let agxntzDir = FileUtil.home.appendingPathComponent(".agxntz")
    static let shimPath = FileUtil.home.appendingPathComponent(".agxntz/claude-hook.sh")
    static let settingsPath = FileUtil.home.appendingPathComponent(".claude/settings.json")

    static let events = ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd"]

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: shimPath.path),
              let data = try? Data(contentsOf: settingsPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("claude-hook.sh")
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: agxntzDir, withIntermediateDirectories: true)

        // Shim always re-points at the current executable.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let shim = """
        #!/bin/sh
        exec "\(exe)" --claude-hook "$1"
        """
        try shim.write(to: shimPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath.path)

        // Merge hook entries into ~/.claude/settings.json.
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = obj
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            let already = matchers.contains { matcher in
                guard let list = matcher["hooks"] as? [[String: Any]] else { return false }
                return list.contains { ($0["command"] as? String)?.contains("claude-hook.sh") == true }
            }
            if !already {
                matchers.append([
                    "hooks": [["type": "command", "command": "\(shimPath.path) \(event)"]]
                ])
                hooks[event] = matchers
            }
        }
        settings["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: settingsPath)
    }

    /// Hook mode: invoked by Claude Code as `agxntz --claude-hook <event>`
    /// with the hook payload on stdin. Must be fast and silent.
    static func runHookMode(event: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var sessionID = "unknown"
        var cwd: String?
        if let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
            sessionID = obj["session_id"] as? String ?? sessionID
            cwd = obj["cwd"] as? String
        }
        var record: [String: Any] = [
            "event": event,
            "sessionId": sessionID,
            "ts": ISO8601.string(from: Date()),
        ]
        if let cwd { record["cwd"] = cwd }
        guard var line = (try? JSONSerialization.data(withJSONObject: record)).flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        line += "\n"

        let file = ClaudeCodeProvider.eventsFile
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
        trimIfNeeded(file: file)
    }

    private static func trimIfNeeded(file: URL, maxBytes: Int = 1_000_000) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > maxBytes else { return }
        let lines = FileUtil.tailLines(of: file, maxBytes: 128 * 1024)
        let kept = lines.suffix(500).joined(separator: "\n") + "\n"
        try? kept.write(to: file, atomically: true, encoding: .utf8)
    }
}
