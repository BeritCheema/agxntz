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
    // Working directories of agent processes that currently have a live command
    // shell child — i.e. a Bash/command tool actually executing right now.
    private let executingCwds: Set<String>

    init(kindsRunning: Set<AgentKind>, cwdsByKind: [AgentKind: Set<String>], openFiles: Set<String>,
         executingCwds: Set<String> = []) {
        self.kindsRunning = kindsRunning
        self.cwdsByKind = cwdsByKind
        self.openFiles = openFiles
        self.executingCwds = executingCwds
    }

    func isRunning(_ kind: AgentKind) -> Bool { kindsRunning.contains(kind) }

    /// Whether an agent process at (or above) this session's cwd currently has a
    /// live command shell running — a tool actively executing. Distinguishes a
    /// running tool (working) from an agent idle on a permission prompt
    /// (waiting), which look identical in the transcript.
    ///
    /// The session is attributed to the agent process whose cwd is the *most
    /// specific* match (equal to, or the deepest ancestor of, the session cwd).
    /// Matching any ancestor would let one agent launched in a parent folder
    /// (e.g. ~/Projects) that is running a command make every session beneath
    /// it look busy, masking their real permission prompts.
    func hasRunningCommand(_ kind: AgentKind, cwd: String?) -> Bool {
        guard let cwd, !executingCwds.isEmpty, let cwds = cwdsByKind[kind] else { return false }
        let target = Self.normalize(cwd)
        let owner = cwds
            .filter { target == $0 || target.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let owner else { return false }
        return executingCwds.contains(owner)
    }

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

    // Spawning `ps` + `lsof` every poll (once per second) was a large share of
    // idle CPU. Process liveness changes over minutes and the retention windows
    // are minutes, so a snapshot is cached and only rebuilt every few seconds.
    nonisolated(unsafe) private static var cached: ProcessSnapshot?
    nonisolated(unsafe) private static var cachedAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 5
    private static let cacheLock = NSLock()

    static func capture() -> ProcessSnapshot {
        cacheLock.lock()
        if let cached, Date().timeIntervalSince(cachedAt) < cacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        let snapshot = captureFresh()
        cacheLock.lock()
        cached = snapshot
        cachedAt = Date()
        cacheLock.unlock()
        return snapshot
    }

    private static func captureFresh() -> ProcessSnapshot {
        // ppid lets us see each agent process's children — a running command
        // shell means a tool is actively executing.
        guard let psOutput = run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else {
            return ProcessSnapshot(kindsRunning: Set(AgentKind.allCases), cwdsByKind: [:], openFiles: [])
        }

        var kindByPid: [String: AgentKind] = [:]
        var kindsRunning = Set<AgentKind>()
        var procs: [(pid: String, ppid: String, command: Substring)] = []
        let nameToKind: [String: AgentKind] = Dictionary(
            AgentKind.allCases.flatMap { kind in kind.processNames.map { ($0, kind) } },
            uniquingKeysWith: { a, _ in a }
        )
        for line in psOutput.split(separator: "\n") {
            let parts = line.drop { $0 == " " }.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let pid = String(parts[0]), ppid = String(parts[1])
            let command = parts.count >= 3 ? parts[2] : ""
            procs.append((pid, ppid, command))
            var matched: AgentKind?
            for token in command.split(separator: " ").prefix(2) {
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

        // Agent pids that have a live command-shell child: the agent is running
        // a Bash/command tool right now (idle agents waiting on a permission
        // prompt have no such child). Persistent helpers (caffeinate, LSP) are
        // not shells, so they don't count.
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
        var executingPids = Set<String>()
        for p in procs where kindByPid[p.ppid] != nil {
            let firstTok = p.command.split(separator: " ").first.map(String.init) ?? ""
            let base = (firstTok as NSString).lastPathComponent
            if shells.contains(base) || p.command.contains("shell-snapshots") {
                executingPids.insert(p.ppid)
            }
        }

        // One lsof over the agent pids yields cwds (fd "cwd"), open transcript
        // files (numeric fds pointing at .jsonl/.json), and — via a per-pid cwd
        // map — the cwds of the processes currently executing a command.
        var cwdsByKind: [AgentKind: Set<String>] = [:]
        var openFiles = Set<String>()
        var pidCwd: [String: String] = [:]
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
                        let n = normalize(value)
                        cwdsByKind[kind, default: []].insert(n)
                        pidCwd[pid] = n
                    } else if value.hasSuffix(".jsonl") || value.hasSuffix(".json") {
                        openFiles.insert(normalize(value))
                    }
                default: break
                }
            }
        }

        let executingCwds = Set(executingPids.compactMap { pidCwd[$0] })
        return ProcessSnapshot(kindsRunning: kindsRunning, cwdsByKind: cwdsByKind,
                               openFiles: openFiles, executingCwds: executingCwds)
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
