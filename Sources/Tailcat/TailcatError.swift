import CTailcat
import Foundation

/// A failed tailcat call. `code` mirrors the C library's `TC_*` status.
///
/// The text never carries an address, a key or a network endpoint: the C library's message is
/// passed through `Redaction.scrub` before it is stored.
public struct TailcatError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: Int32, Sendable, Equatable {
        case invalidArgument = 1
        case closed = 2
        case timeout = 3
        case cancelled = 4
        case failure = 5
        case eof = 6
    }

    public let code: Code
    /// The wrapper operation that failed, such as `client.dial`.
    public let operation: String
    /// The C library's message with secrets and endpoints removed, if it gave one.
    public let detail: String?

    init(_ code: Code, _ operation: String, detail: String? = nil) {
        self.code = code
        self.operation = operation
        self.detail = detail
    }

    /// Builds an error from a non-OK C status. `secrets` are values the caller passed into the
    /// call (addresses, keys) that must not appear in the stored text.
    init(status: Int32, operation: String, message: String?, secrets: [String] = []) {
        self.code = Code(rawValue: status) ?? .failure
        self.operation = operation
        self.detail = message.map { Redaction.scrub($0, secrets: secrets) }
    }

    public var description: String {
        var text = "tailcat \(operation) failed: \(code)"
        if let detail, !detail.isEmpty { text += " (\(detail))" }
        return text
    }

    public var errorDescription: String? { description }
}
