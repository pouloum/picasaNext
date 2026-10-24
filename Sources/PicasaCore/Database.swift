import Foundation
import SQLite3

public enum DBError: Error, CustomStringConvertible {
    case sqlite(code: Int32, message: String, sql: String?)
    public var description: String {
        switch self {
        case let .sqlite(code, message, sql): "SQLite \(code): \(message)" + (sql.map { " [\($0)]" } ?? "")
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Value bound to / read from a statement.
public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// Minimal SQLite wrapper. One connection per instance; not thread-safe — wrap in an actor.
public final class Database: @unchecked Sendable {
    let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            throw DBError.sqlite(code: -1, message: "cannot open \(path)", sql: nil)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=268435456;")
        }
    }

    deinit {
        for s in cache.values { sqlite3_finalize(s) }
        sqlite3_close_v2(handle)
    }

    private func error(_ code: Int32, _ sql: String?) -> DBError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func exec(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil)
        guard rc == SQLITE_OK, let s else { throw error(rc, sql) }
        cache[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ args: [SQLBindable]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a.sqlValue {
            case .null: sqlite3_bind_null(s, idx)
            case let .int(v): sqlite3_bind_int64(s, idx, v)
            case let .double(v): sqlite3_bind_double(s, idx, v)
            case let .text(v): sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case let .blob(v): v.withUnsafeBytes { _ = sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
    }

    /// Execute a statement that returns no rows.
    @discardableResult
    public func run(_ sql: String, _ args: SQLBindable...) throws -> Int64 {
        try run(sql, args)
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLBindable]) throws -> Int64 {
        let s = try prepare(sql)
        bind(s, args)
        var rc = sqlite3_step(s)
        while rc == SQLITE_ROW { rc = sqlite3_step(s) }
        guard rc == SQLITE_DONE else { throw error(rc, sql) }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    /// Rows changed by this connection since it was opened.
    public var totalChanges: Int64 { sqlite3_total_changes64(handle) }

    /// Iterate rows; the Row is only valid inside the closure.
    public func query(_ sql: String, _ args: [SQLBindable] = [], _ body: (Row) throws -> Void) throws {
        let s = try prepare(sql)
        bind(s, args)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            try body(Row(stmt: s))
        }
    }

    public func all<T>(_ sql: String, _ args: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(sql, args) { out.append(try map($0)) }
        return out
    }

    public func scalar(_ sql: String, _ args: [SQLBindable] = []) throws -> Int64? {
        var v: Int64?
        try query(sql, args) { v = $0.isNull(0) ? nil : $0.int(0) }
        return v
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public struct Row {
        let stmt: OpaquePointer
        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
        public func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
        public func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        public func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
        public func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
