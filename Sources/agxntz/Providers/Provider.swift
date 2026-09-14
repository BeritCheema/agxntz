import Foundation

protocol AgentProvider {
    var kind: AgentKind { get }
    func scan(now: Date, processes: ProcessSnapshot) -> [AgentSession]
}

enum FileUtil {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Files directly inside `dir` (no recursion), with their mtimes,
    /// filtered to those touched within Tuning.scanWindow.
    static func recentFiles(in dir: URL, suffix: String? = nil, now: Date) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(URL, Date)] = []
        for url in items {
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  now.timeIntervalSince(mtime) < Tuning.scanWindow
            else { continue }
            out.append((url, mtime))
        }
        return out
    }

    static func subdirectories(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []
    }

    /// Last `maxBytes` of a file, split into complete lines. Splits on newline
    /// bytes and decodes each line individually so a half-written trailing
    /// record (the file is being appended to live, often ending mid-UTF-8
    /// character) can't fail the decode of the whole tail — which would
    /// momentarily blank the session. Undecodable/partial lines are skipped.
    static func tailLines(of url: URL, maxBytes: Int = 128 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }

        let newline = UInt8(ascii: "\n")
        var segments = data.split(separator: newline, omittingEmptySubsequences: false)
        // Drop the partial first line (window started mid-record).
        if offset > 0, !segments.isEmpty { segments.removeFirst() }
        return segments.compactMap { seg in
            seg.isEmpty ? nil : String(data: Data(seg), encoding: .utf8)
        }
    }

    /// First complete line of a file. Reads in growing chunks: some agents
    /// write very large metadata first lines (Codex embeds its full base
    /// instructions, >18KB), so a fixed small read would truncate mid-line
    /// and break JSON parsing.
    static func firstLine(of url: URL, capBytes: Int = 4 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var chunkSize = 16 * 1024
        while buffer.count < capBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.contains(UInt8(ascii: "\n")) { break }
            chunkSize *= 2
        }
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
        }
        return String(data: buffer[..<newline], encoding: .utf8)
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func newestMtime(under dir: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: Date?
        for case let url as URL in enumerator {
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if newest == nil || m > newest! { newest = m }
            }
        }
        return newest
    }
}

extension String {
    var projectNameFromPath: String {
        let name = (self as NSString).lastPathComponent
        return name.isEmpty ? self : name
    }
}
