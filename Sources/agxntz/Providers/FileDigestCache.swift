import Foundation

/// Caches an expensive per-file parse ("digest") keyed on the file's mtime and
/// size, so an unchanged transcript is read and JSON-parsed once rather than on
/// every poll. State that depends on wall-clock time or process liveness is
/// re-derived cheaply each tick from the cached digest — only the file-byte
/// extraction is memoized here.
///
/// Reference type so a value-type provider can hold one via a `let` property and
/// still mutate the cache across scans. Thread-safe: scans run on a background
/// queue.
final class FileDigestCache<Digest> {
    private struct Entry { let mtime: Date; let size: UInt64; let digest: Digest }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    /// Return the cached digest if the file is unchanged (same mtime + size);
    /// otherwise run `produce`, cache, and return it. A nil from `produce` is
    /// not cached (transient read failure shouldn't stick).
    func value(for url: URL, mtime: Date, produce: () -> Digest?) -> Digest? {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(UInt64.init) ?? 0
        let key = url.path
        lock.lock()
        if let e = entries[key], e.mtime == mtime, e.size == size {
            lock.unlock()
            return e.digest
        }
        lock.unlock()

        guard let digest = produce() else { return nil }
        lock.lock()
        entries[key] = Entry(mtime: mtime, size: size, digest: digest)
        lock.unlock()
        return digest
    }

    /// Drop entries for files no longer present so the cache can't grow without
    /// bound as sessions come and go.
    func prune(keeping keep: Set<String>) {
        lock.lock()
        entries = entries.filter { keep.contains($0.key) }
        lock.unlock()
    }
}
