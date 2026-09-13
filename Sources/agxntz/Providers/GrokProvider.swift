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
        let alive = processes.isLive(kind, cwd: cwd, transcriptPath: file.path)
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

        if Tuning.shouldDrop(state: state, alive: alive, age: age) { return nil }

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
            startedAt: FileUtil.creationDate(of: file) ?? mtime, lastActivityAt: mtime,
            lastMessage: latestAssistantText(in: file)?.messageSnippet
        )
    }

    /// Best-effort: newest assistant-authored text in an undocumented JSONL
    /// transcript. Looks for role=assistant records and pulls string content
    /// or text fields out of content arrays.
    private static func latestAssistantText(in file: URL) -> String? {
        for line in FileUtil.tailLines(of: file, maxBytes: 64 * 1024).suffix(40).reversed() {
            guard line.contains("assistant"), let obj = FileUtil.json(line) else { continue }
            // The message may be the record itself or nested under "message".
            for candidate in [obj, obj["message"] as? [String: Any] ?? [:]] {
                guard candidate["role"] as? String == "assistant" else { continue }
                if let text = candidate["content"] as? String, !text.isEmpty { return text }
                if let content = candidate["content"] as? [[String: Any]] {
                    let texts = content.compactMap { item -> String? in
                        ["text", "output_text"].contains(item["type"] as? String ?? "") ? item["text"] as? String : nil
                    }
                    if !texts.isEmpty { return texts.joined(separator: " ") }
                }
            }
        }
        return nil
    }
}
