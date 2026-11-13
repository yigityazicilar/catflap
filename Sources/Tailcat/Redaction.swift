import Foundation

/// Removes secrets and network endpoints from text that may reach logs or the user.
///
/// tailcat addresses and keys are secrets. The C library avoids echoing them, but its messages can
/// wrap errors from lower layers, so the wrapper does not rely on that.
enum Redaction {
    static let marker = "<redacted>"

    static func scrub(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: marker)
        }
        return result
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { looksSensitive($0) ? marker : String($0) }
            .joined(separator: " ")
    }

    private static let opaque = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=_:.-[]%")
    private static let ipv4 = Set("0123456789.:")
    private static let ipv6 = Set("0123456789abcdefABCDEF:.[]%")
    private static let punctuation = Set("\"'`(),;")

    /// True for long opaque runs (addresses and keys are long encoded strings) and for IP
    /// literals, with or without a port.
    static func looksSensitive(_ word: Substring) -> Bool {
        var token = word
        while let first = token.first, punctuation.contains(first) { token = token.dropFirst() }
        while let last = token.last, punctuation.contains(last) { token = token.dropLast() }
        if token.isEmpty { return false }
        if token.count >= 20 && token.allSatisfy({ opaque.contains($0) }) { return true }
        if token.filter({ $0 == "." }).count >= 3 && token.allSatisfy({ ipv4.contains($0) }) { return true }
        if token.filter({ $0 == ":" }).count >= 2 && token.allSatisfy({ ipv6.contains($0) }) { return true }
        return false
    }
}
