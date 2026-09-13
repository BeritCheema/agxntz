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

    /// Last `maxBytes` of a file, split into complete lines.
    static func tailLines(of url: URL, maxBytes: Int = 128 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // drop partial first line
        return lines
    }

    static func firstLine(of url: URL, maxBytes: Int = 16 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
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
