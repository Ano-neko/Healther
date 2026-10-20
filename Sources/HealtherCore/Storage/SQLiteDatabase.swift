import Foundation

#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// Anything that can be bound as a statement parameter.
public protocol SQLBindable: Sendable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension UUID: SQLBindable { public var sqlValue: SQLValue { .text(uuidString) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?
    public var description: String { "SQLite error \(code): \(message)" + (sql.map { " — \($0.prefix(160))" } ?? "") }
}

public struct Row: Sendable {
    public let columns: [String]
    public let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let i = columns.firstIndex(of: name) else { return .null }
        return values[i]
    }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        default: return nil
        }
    }

    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
}

/// A thread-safe SQLite connection. All access is serialized by a recursive lock, so
/// `transaction` bodies may call back into the same database.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        if !readOnly {
            try executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        }
    }

    /// In-memory database (tests).
    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, sql: sql)
        }
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [(any SQLBindable)?] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [(any SQLBindable)?] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let count = sqlite3_column_count(stmt)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 {
                        values.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        values.append(.blob(Data()))
                    }
                default: values.append(.null)
                }
            }
            rows.append(Row(columns: columns, values: values))
        }
        return rows
    }

    public func queryOne(_ sql: String, _ params: [(any SQLBindable)?] = []) throws -> Row? {
        try query(sql, params).first
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction (nested calls join the outer transaction).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let outermost = sqlite3_get_autocommit(handle) != 0
        if outermost { try executeScript("BEGIN IMMEDIATE") }
        do {
            let result = try body()
            if outermost { try executeScript("COMMIT") }
            return result
        } catch {
            if outermost { try? executeScript("ROLLBACK") }
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? queryOne("PRAGMA user_version")?.int("user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try executeScript("PRAGMA user_version = \(v)") }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }

    private func prepare(_ sql: String, _ params: [(any SQLBindable)?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let r: Int32
            switch p?.sqlValue ?? .null {
            case .null: r = sqlite3_bind_null(stmt, idx)
            case .int(let v): r = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): r = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): r = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                r = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            }
            if r != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw error(r, sql)
            }
        }
        return stmt
    }
}
