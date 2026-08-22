import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null

    var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let d): return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite error: \(message)" }
}

// Minimal serialized wrapper over the system SQLite. All access goes through
// one queue, so instances are safe to share across tasks.
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "flyleaf.sqlite")

    init(path: String) throws {
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw SQLiteError(message: msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    func exec(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw SQLiteError(message: msg)
            }
        }
    }

    func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        _ = try query(sql, params)
    }

    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            for (i, p) in params.enumerated() {
                let idx = Int32(i + 1)
                switch p {
                case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                case .int(let n): sqlite3_bind_int64(stmt, idx, n)
                case .real(let d): sqlite3_bind_double(stmt, idx, d)
                case .null: sqlite3_bind_null(stmt, idx)
                }
            }

            var rows = [[String: SQLiteValue]]()
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
                }
                var row = [String: SQLiteValue]()
                for col in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, col))
                    switch sqlite3_column_type(stmt, col) {
                    case SQLITE_TEXT:
                        row[name] = .text(String(cString: sqlite3_column_text(stmt, col)))
                    case SQLITE_INTEGER:
                        row[name] = .int(sqlite3_column_int64(stmt, col))
                    case SQLITE_FLOAT:
                        row[name] = .real(sqlite3_column_double(stmt, col))
                    default:
                        row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }
}
