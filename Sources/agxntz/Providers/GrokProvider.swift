import Foundation

/// Grok CLI (x.ai): sessions under ~/.grok/sessions/<url-encoded-cwd>/,
/// one directory per session (override base with GROK_HOME). Format is not
/// publicly documented, so state uses the shared JSONL-tail heuristics.
struct GrokProvider: AgentProvider {
    let kind = AgentKind.grok

    private var sessionsDir: URL {
        if let base = ProcessInfo.processInfo.environment["GROK_HOME"] {
            return URL(fileURLWithPath: base).appendingPathComponent("sessions")
        }
        return FileUtil.home.appendingPathComponent(".grok/sessions")
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for groupDir in FileUtil.subdirectories(of: sessionsDir) {
            let cwd = Self.decodeGroup(groupDir)
            // Sessions may be directories (one per session) or bare files.
            for sessionDir in FileUtil.subdirectories(of: groupDir) {
                if let s = GenericTailClassifier.session(
                    idPrefix: "grok", kind: kind, container: sessionDir, cwd: cwd,
                    now: now, processes: processes
                ) { sessions.append(s) }
            }
            for (file, mtime) in FileUtil.recentFiles(in: groupDir, now: now) where file.pathExtension == "jsonl" || file.pathExtension == "json" {
                if let s = GenericTailClassifier.session(
                    idPrefix: "grok", kind: kind, file: file, mtime: mtime, cwd: cwd,
                    now: now, processes: processes
                ) { sessions.append(s) }
            }
        }
        return sessions
    }

    private static func decodeGroup(_ dir: URL) -> String? {
        let cwdFile = dir.appendingPathComponent(".cwd")
        if let recorded = try? String(contentsOf: cwdFile, encoding: .utf8) {
            return recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return dir.lastPathComponent.removingPercentEncoding
    }
}

/// Pi (badlogic/pi-mono): tree-structured JSONL sessions under
/// ~/.pi/agent/sessions/, grouped by working directory
/// (override with PI_CODING_AGENT_SESSION_DIR).
struct PiProvider: AgentProvider {
    let kind = AgentKind.pi

    private var sessionsDir: URL {
        if let base = ProcessInfo.processInfo.environment["PI_CODING_AGENT_SESSION_DIR"] {
            return URL(fileURLWithPath: base)
        }
        return FileUtil.home.appendingPathComponent(".pi/agent/sessions")
    }

    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for groupDir in FileUtil.subdirectories(of: sessionsDir) {
            // Group dirs encode the cwd with dashes (like Claude Code).
            let cwd = groupDir.lastPathComponent.replacingOccurrences(of: "-", with: "/")
            for (file, mtime) in FileUtil.recentFiles(in: groupDir, suffix: ".jsonl", now: now) {
                if let s = GenericTailClassifier.session(
                    idPrefix: "pi", kind: kind, file: file, mtime: mtime, cwd: cwd,
                    now: now, processes: processes
                ) { sessions.append(s) }
            }
        }
        return sessions
    }
}

/// Best-effort state classification for agents whose transcript format we
/// don't parse structurally: look at the raw last JSONL line for
/// role/tool-call markers, otherwise fall back to mtime + process liveness.
enum GenericTailClassifier {
    static func session(idPrefix: String, kind: AgentKind, container: URL,
                        cwd: String?, now: Date, processes: ProcessSnapshot) -> AgentSession? {
        // Find the newest transcript-looking file inside the session dir.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: container, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in enumerator where ["jsonl", "json"].contains(url.pathExtension) {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if newest == nil || m > newest!.1 { newest = (url, m) }
        }
        guard let (file, mtime) = newest, now.timeIntervalSince(mtime) < Tuning.scanWindow else { return nil }
        return session(idPrefix: idPrefix, kind: kind, file: file, mtime: mtime, cwd: cwd,
                       now: now, processes: processes, id: container.lastPathComponent)
    }

    static func session(idPrefix: String, kind: AgentKind, file: URL, mtime: Date,
                        cwd: String?, now: Date, processes: ProcessSnapshot,
                        id: String? = nil) -> AgentSession? {
        let age = now.timeIntervalSince(mtime)
        let alive = processes.isRunning(kind)
        let lastLine = FileUtil.tailLines(of: file, maxBytes: 32 * 1024).last ?? ""

        let assistantEnded = lastLine.contains("\"role\":\"assistant\"") || lastLine.contains("\"role\": \"assistant\"")
        let pendingTool = ["tool_use", "toolCall", "tool_call", "function_call"]
            .contains { lastLine.contains("\"\($0)\"") }

        var state: SessionState
        if age < Tuning.workingWindow {
            state = .working
        } else if pendingTool {
            state = alive ? .waiting : .done
        } else if assistantEnded {
            state = .done
        } else {
            state = age < 90 ? .working : (alive ? .waiting : .done)
        }

        if state != .done && !alive { return nil }
        if state == .done && age > Tuning.doneRetention { return nil }

        let activity: String
        switch state {
        case .working: activity = "working"
        case .waiting: activity = "waiting for you"
        case .done: activity = "finished"
        }

        let sessionID = id ?? file.deletingPathExtension().lastPathComponent
        return AgentSession(
            id: "\(idPrefix):\(sessionID)", kind: kind,
            projectName: (cwd ?? idPrefix).projectNameFromPath, cwd: cwd,
            activity: activity, state: state,
            startedAt: FileUtil.creationDate(of: file) ?? mtime, lastActivityAt: mtime
        )
    }
}
