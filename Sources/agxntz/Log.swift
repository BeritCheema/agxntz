import Foundation

/// Debug logging, off by default. Enabled by launching with `--debug`
/// (or AGXNTZ_DEBUG=1). Lines go to stderr and ~/.agxntz/debug.log.
enum Log {
    nonisolated(unsafe) static var enabled = false

    private static let file = FileUtil.home.appendingPathComponent(".agxntz/debug.log")
    private static let queue = DispatchQueue(label: "agxntz.log", qos: .utility)

    static func d(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(ISO8601.string(from: Date())) \(message())\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
                trimIfNeeded()
            }
        }
    }

    private static func trimIfNeeded(maxBytes: Int = 2_000_000) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > maxBytes else { return }
        let kept = FileUtil.tailLines(of: file, maxBytes: 256 * 1024).suffix(2000).joined(separator: "\n") + "\n"
        try? kept.write(to: file, atomically: true, encoding: .utf8)
    }
}
