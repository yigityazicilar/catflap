import CSQLite
import Foundation

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
public typealias SQLRow = [String: SQLValue]

/// A synchronous, scoped transaction view. Do not retain it or issue transaction-control SQL.
/// The store actor prevents interleaving; the view becomes invalid when its body returns.
public final class SQLTransaction {
    private let db: OpaquePointer
    private var valid = true
    init(_ db: OpaquePointer) { self.db = db }
    func invalidate() { valid = false }
    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        guard valid, !sql.utf8.contains(0) else { throw AgentError.storage }
        // Only Store owns transaction boundaries, even when SQL contains leading comments.
        sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
            action == SQLITE_TRANSACTION || action == SQLITE_SAVEPOINT ? SQLITE_DENY : SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(db, nil, nil) }
        var statement: OpaquePointer?
        let code = sql.withCString { source in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(db, source, -1, &statement, &tail)
            if code == SQLITE_OK, let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SQLITE_MISUSE
            }
            return code
        }
        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw AgentError.storage
        }
        do {
            guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else { throw AgentError.storage }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let bound: Int32
                switch value {
                case .null: bound = sqlite3_bind_null(statement, index)
                case .integer(let number): bound = sqlite3_bind_int64(statement, index, number)
                case .real(let number): bound = sqlite3_bind_double(statement, index, number)
                case .text(let text):
                    guard text.utf8.count <= Int(Int32.max) else { throw AgentError.storage }
                    bound = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
                case .blob(let data):
                    guard data.count <= Int(Int32.max) else { throw AgentError.storage }
                    if data.isEmpty { bound = sqlite3_bind_zeroblob(statement, index, 0) }
                    else { bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
                }
                guard bound == SQLITE_OK else { throw AgentError.storage }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    public func execute(_ sql: String, bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AgentError.storage }
    }
    public func query(_ sql: String, bindings: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw AgentError.storage }
            var row: SQLRow = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                let value: SQLValue
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: value = .null
                case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: value = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let bytes = UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: count)
                    value = .text(String(decoding: bytes, as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if count == 0 { value = .blob(Data()) }
                    else if let pointer = sqlite3_column_blob(statement, column) { value = .blob(Data(bytes: pointer, count: count)) }
                    else { throw AgentError.storage }
                default: throw AgentError.storage
                }
                guard row.updateValue(value, forKey: name) == nil else { throw AgentError.storage }
            }
            rows.append(row)
        }
    }
}
