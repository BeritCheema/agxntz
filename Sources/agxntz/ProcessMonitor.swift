import Foundation

/// Snapshot of running processes, refreshed once per scan tick.
/// Used to distinguish "agent finished / waiting" from "agent gone".
struct ProcessSnapshot {
    private let commandBasenames: Set<String>

    init(commandBasenames: Set<String>) {
        self.commandBasenames = commandBasenames
    }

    func isRunning(_ kind: AgentKind) -> Bool {
        kind.processNames.contains { commandBasenames.contains($0) }
    }

    static func capture() -> ProcessSnapshot {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        var names = Set<String>()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else {
                return ProcessSnapshot(commandBasenames: [])
            }
            for line in output.split(separator: "\n") {
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                // The agent CLIs are node/bun scripts or bare binaries; the
                // executable name shows up as the basename of the first or
                // second token ("node /path/to/claude ..." or "claude ...").
                for token in tokens.prefix(2) {
                    let base = (String(token) as NSString).lastPathComponent
                    names.insert(base)
                }
            }
        } catch {
            // If ps fails, err on the side of "everything is running" so we
            // don't drop live sessions; an empty set would hide them.
            return ProcessSnapshot(commandBasenames: Set(AgentKind.allCases.flatMap(\.processNames)))
        }
        return ProcessSnapshot(commandBasenames: names)
    }
}
