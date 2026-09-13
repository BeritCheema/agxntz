import Foundation
import SQLite3

/// Minimal read-only SQLite reader for agents that store sessions in a DB
/// (OpenCode). Opens per scan, reads, closes — cheap, and avoids holding
/// locks against the live writer processes. WAL frames are visible because
/// the owning processes keep the -shm/-wal files present.
final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(readonlyPath: String) {
        guard FileManager.default.fileExists(atPath: readonlyPath) else { return nil }
        var h: OpaquePointer?
        if sqlite3_open_v2(readonlyPath, &h, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(h)
            return nil
        }
        handle = h
        sqlite3_busy_timeout(handle, 200)
    }

    deinit { if let handle { sqlite3_close(handle) } }

    /// Runs `sql` with positional text binds, returning rows of string columns
    /// (nil for SQL NULL).
    func query(_ sql: String, _ binds: [String] = []) -> [[String?]] {
        guard let handle else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), bind, -1, Self.transient)
        }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [String?] = []
            row.reserveCapacity(Int(count))
            for c in 0..<count {
                if let cstr = sqlite3_column_text(stmt, c) {
                    row.append(String(cString: cstr))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
