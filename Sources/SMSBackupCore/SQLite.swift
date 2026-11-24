import Foundation
import SQLite3

public struct SQLiteError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "SQLite: \(message)" }
    public var errorDescription: String? { description }
}

let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public protocol SQLBindable {}
extension Int: SQLBindable {}
extension Int32: SQLBindable {}
extension Int64: SQLBindable {}
extension Double: SQLBindable {}
extension Bool: SQLBindable {}
extension String: SQLBindable {}
extension Data: SQLBindable {}

/// Thin wrapper around a SQLite connection. Opened with FULLMUTEX so a single
/// connection may be used from multiple threads (calls are serialized by SQLite).
public final class SQLiteDB: @unchecked Sendable {
    public let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags: Int32 = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "error code \(rc)"
            if let h { sqlite3_close(h) }
            throw SQLiteError("cannot open \(path): \(msg)")
        }
        handle = opened
        sqlite3_busy_timeout(opened, 10_000)
    }

    deinit { sqlite3_close_v2(handle) }

    public var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        try Statement(db: self, sql: sql)
    }

    /// Convenience: run a query and map each row.
    public func query<T>(_ sql: String, _ params: [SQLBindable?] = [], map: (Statement) throws -> T) throws -> [T] {
        let st = try prepare(sql)
        try st.bind(params)
        var out: [T] = []
        while try st.step() { out.append(try map(st)) }
        return out
    }

    public func scalarInt(_ sql: String, _ params: [SQLBindable?] = []) throws -> Int64? {
        let st = try prepare(sql)
        try st.bind(params)
        guard try st.step(), !st.isNull(0) else { return nil }
        return st.int64(0)
    }
}

public final class Statement {
    let stmt: OpaquePointer
    let db: SQLiteDB

    init(db: SQLiteDB, sql: String) throws {
        self.db = db
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else {
            throw SQLiteError("prepare failed (\(db.errorMessage)) for: \(sql)")
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    public func bind(_ values: [SQLBindable?]) throws -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case nil:
                rc = sqlite3_bind_null(stmt, idx)
            case let v as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int32:
                rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                rc = sqlite3_bind_double(stmt, idx, v)
            case let v as Bool:
                rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as String:
                rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case let v as Data:
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob64(stmt, idx, raw.baseAddress, sqlite3_uint64(v.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            default:
                rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw SQLiteError("bind failed: \(db.errorMessage)") }
        }
        return self
    }

    /// Returns true if a row is available, false when done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError("step failed: \(db.errorMessage)")
        }
    }

    /// Bind + execute to completion.
    public func run(_ values: [SQLBindable?] = []) throws {
        try bind(values)
        while try step() {}
    }

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func optInt64(_ i: Int32) -> Int64? { isNull(i) ? nil : int64(i) }

    public func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    public func data(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}
