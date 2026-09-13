import Foundation

/// Snapshot of running agent processes — their kinds, working directories,
/// and open transcript files — refreshed once per scan tick. Lets a session
/// be tied, best-effort, to a live process rather than to "any agent of this
/// kind". No single signal is reliable across all agents, so several are
/// combined and we err toward "alive" to avoid dropping live sessions.
struct ProcessSnapshot {
    private let kindsRunning: Set<AgentKind>
    private let cwdsByKind: [AgentKind: Set<String>]
    private let openFiles: Set<String>

    init(kindsRunning: Set<AgentKind>, cwdsByKind: [AgentKind: Set<String>], openFiles: Set<String>) {
        self.kindsRunning = kindsRunning
        self.cwdsByKind = cwdsByKind
        self.openFiles = openFiles
    }

    func isRunning(_ kind: AgentKind) -> Bool { kindsRunning.contains(kind) }

    /// Best-effort: is this specific session backed by a live process.
    /// Signals, strongest first:
    ///  1. A process holds the session's transcript file open (exact; works
    ///     for agents that keep the file open, e.g. Codex).
    ///  2. A process of this kind runs in the session's cwd, or in an ancestor
    ///     of it (agents are often launched in a parent dir and `cd` into the
    ///     project, so the process cwd is at or above the session cwd).
    ///  3. If we have no cwd data for this kind at all (lsof failed), fall back
    ///     to the coarse "is the kind running" check so we never hide a live
    ///     session on tooling gaps.
    /// Returns false only when we have cwd data for the kind and none matches —
    /// i.e. we're reasonably confident the session's process is gone.
    func isLive(_ kind: AgentKind, cwd: String?, transcriptPath: String? = nil) -> Bool {
        if let path = transcriptPath, openFiles.contains(Self.normalize(path)) { return true }

        guard let cwd else { return kindsRunning.contains(kind) }
        guard let cwds = cwdsByKind[kind], !cwds.isEmpty else {
            return kindsRunning.contains(kind)
        }
        let target = Self.normalize(cwd)
        for processCwd in cwds {
            if target == processCwd || target.hasPrefix(processCwd + "/") { return true }
        }
        return false
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func capture() -> ProcessSnapshot {
        guard let psOutput = run("/bin/ps", ["-axo", "pid=,command="]) else {
            return ProcessSnapshot(kindsRunning: Set(AgentKind.allCases), cwdsByKind: [:], openFiles: [])
        }

        var kindByPid: [String: AgentKind] = [:]
        var kindsRunning = Set<AgentKind>()
        let nameToKind: [String: AgentKind] = Dictionary(
            AgentKind.allCases.flatMap { kind in kind.processNames.map { ($0, kind) } },
            uniquingKeysWith: { a, _ in a }
        )
        for line in psOutput.split(separator: "\n") {
            let tokens = line.drop { $0 == " " }.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = tokens.first.map(String.init) else { continue }
            var matched: AgentKind?
            for token in tokens.dropFirst().prefix(2) {
                let base = (String(token) as NSString).lastPathComponent
                if let kind = nameToKind[base] { matched = kind; break }
            }
            if let kind = matched {
                kindByPid[pid] = kind
                kindsRunning.insert(kind)
            }
        }

        guard !kindByPid.isEmpty else {
            return ProcessSnapshot(kindsRunning: [], cwdsByKind: [:], openFiles: [])
        }

        // One lsof over the agent pids yields both cwds (fd "cwd") and open
        // transcript files (numeric fds pointing at .jsonl/.json).
        var cwdsByKind: [AgentKind: Set<String>] = [:]
        var openFiles = Set<String>()
        let pidList = kindByPid.keys.joined(separator: ",")
        if let lsof = run("/usr/sbin/lsof", ["-a", "-p", pidList, "-Fpfn"]) {
            var pid: String?
            var fd: String?
            for line in lsof.split(separator: "\n") {
                guard let tag = line.first else { continue }
                let value = String(line.dropFirst())
                switch tag {
                case "p": pid = value; fd = nil
                case "f": fd = value
                case "n":
                    guard let pid, let kind = kindByPid[pid] else { continue }
                    if fd == "cwd" {
                        cwdsByKind[kind, default: []].insert(normalize(value))
                    } else if value.hasSuffix(".jsonl") || value.hasSuffix(".json") {
                        openFiles.insert(normalize(value))
                    }
                default: break
                }
            }
        }

        return ProcessSnapshot(kindsRunning: kindsRunning, cwdsByKind: cwdsByKind, openFiles: openFiles)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
