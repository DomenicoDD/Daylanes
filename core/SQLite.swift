import Foundation
import SQLite3

/// A value read from or bound to SQLite.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int: Int? {
        switch self {
        case let .integer(value): Int(value)
        case let .real(value): Int(value)
        default: nil
        }
    }
    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }
    var isNull: Bool { self == .null }

    var json: JSON {
        switch self {
        case .null: .null
        case let .integer(value): .int(value)
        case let .real(value): .double(value)
        case let .text(value): .string(value)
        case let .blob(value): .string(value.base64EncodedString())
        }
    }
}

protocol SQLBindable { var sqlValue: SQLValue { get } }
extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row, readable by column name (like Python's sqlite3.Row) or position.
struct Row {
    let columns: [String]
    let values: [SQLValue]

    subscript(_ name: String) -> SQLValue {
        guard let index = columns.firstIndex(of: name) else { return .null }
        return values[index]
    }
    subscript(_ index: Int) -> SQLValue { values[index] }

    /// The row as a JSON object, keeping the column order (like `dict(row)` in Python).
    var object: JSON { .object(zip(columns, values.map(\.json)).map { ($0, $1) }) }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small wrapper over the system libsqlite3, enough for the ledger.
final class Database {
    private var handle: OpaquePointer?
    let path: String

    /// Opens another tool's database read-only, so Tracker never writes to it (committed WAL data is still read).
    static func readOnly(_ path: String, timeout: TimeInterval = 2) throws -> Database {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        return try Database(path: uri, timeout: timeout, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX)
    }

    init(path: String, timeout: TimeInterval = 15,
         flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) throws {
        self.path = path
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database file"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, Int32(timeout * 1000))
    }

    /// Prepared statements by SQL text, reused like Python's sqlite3 statement cache: an import runs
    /// the same upsert hundreds of thousands of times.
    private var statements: [String: OpaquePointer] = [:]

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        if let cached = statements.removeValue(forKey: sql) { return cached }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw error(prepared)
        }
        return statement
    }

    /// Returns a statement to the cache, reset and unbound (or finalizes it when the cache is full).
    private func release(_ sql: String, _ statement: OpaquePointer?) {
        guard let statement else { return }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        if statements.count >= 100 {
            sqlite3_finalize(statement)
        } else {
            statements[sql] = statement
        }
    }

    var inTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }
    var changes: Int { Int(sqlite3_changes(handle)) }

    private func error(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements with no parameters and no results.
    func script(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        if status != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw SQLiteError(code: status, message: text)
        }
    }

    /// Runs one statement and returns every row.
    @discardableResult
    func query(_ sql: String, _ parameters: [SQLBindable] = []) throws -> [Row] {
        let statement = try prepare(sql)
        defer { release(sql, statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch parameter.sqlValue {
            case .null: status = sqlite3_bind_null(statement, index)
            case let .integer(value): status = sqlite3_bind_int64(statement, index, value)
            case let .real(value): status = sqlite3_bind_double(statement, index, value)
            case let .text(value): status = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .blob(value):
                status = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient)
                }
            }
            guard status == SQLITE_OK else { throw error(status) }
        }
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { sqlite3_column_name(statement, $0).map { String(cString: $0) } ?? "" }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(step) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for column in 0..<count {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: values.append(.text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) {
                        values.append(.blob(Data(bytes: bytes, count: length)))
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

    /// Runs a statement and returns how many rows it changed.
    @discardableResult
    func execute(_ sql: String, _ parameters: [SQLBindable] = []) throws -> Int {
        try query(sql, parameters)
        return changes
    }

    func first(_ sql: String, _ parameters: [SQLBindable] = []) throws -> Row? {
        try query(sql, parameters).first
    }

    /// Starts a write transaction unless one is open, like the engine's `BEGIN IMMEDIATE`.
    func beginImmediate() throws {
        if !inTransaction { try script("BEGIN IMMEDIATE") }
    }

    /// Runs `body` in a transaction: committed when it returns, rolled back when it throws.
    /// Writes take the lock up front (`BEGIN IMMEDIATE`), so a check and the write after it can't race.
    func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        let outer = inTransaction
        if !outer { try script(immediate ? "BEGIN IMMEDIATE" : "BEGIN") }
        do {
            let result = try body()
            if !outer, inTransaction { try script("COMMIT") }
            return result
        } catch {
            if !outer, inTransaction { try? script("ROLLBACK") }
            throw error
        }
    }
}
