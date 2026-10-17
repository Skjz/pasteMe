import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// 对系统自带 SQLite3 的最小封装，避免引入第三方依赖。
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
    }

    func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError(rc) }
        let statement = SQLiteStatement(stmt, db: self)
        try statement.bind(values)
        return statement
    }

    /// 执行不返回行的语句。
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        while try statement.step() {}
    }

    var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            _ = try statement.step()
            return Int(statement.int(0))
        }
    }

    func lastError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let db: SQLiteDatabase

    /// 让 SQLite 在 bind 时复制数据，调用方的缓冲区可以立即释放。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ stmt: OpaquePointer, db: SQLiteDatabase) {
        self.stmt = stmt
        self.db = db
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, index)
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, index, v)
            case .double(let v):
                rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw db.lastError(rc) }
        }
    }

    /// 前进一行。有数据返回 true，执行完毕返回 false。
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.lastError(rc)
        }
    }

    var columnCount: Int32 { sqlite3_column_count(stmt) }

    func columnName(_ column: Int32) -> String {
        String(cString: sqlite3_column_name(stmt, column))
    }

    /// 按这一列实际存的类型读出值，用于原样保存和放回整行。
    func value(_ column: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_INTEGER: .int(int(column))
        case SQLITE_FLOAT: .double(double(column))
        case SQLITE_TEXT: text(column).map(SQLValue.text) ?? .null
        case SQLITE_BLOB: .blob(blob(column) ?? Data())
        default: .null
        }
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(stmt, column) == SQLITE_NULL
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(stmt, column)
    }

    func text(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    func blob(_ column: Int32) -> Data? {
        guard !isNull(column), let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }
}

extension Optional where Wrapped == String {
    var sqlValue: SQLValue { map(SQLValue.text) ?? .null }
}

extension Optional where Wrapped == Data {
    var sqlValue: SQLValue { map(SQLValue.blob) ?? .null }
}

extension Optional where Wrapped == Int64 {
    var sqlValue: SQLValue { map(SQLValue.int) ?? .null }
}
