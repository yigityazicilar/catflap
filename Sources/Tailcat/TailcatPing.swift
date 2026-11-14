import CTailcat
import Foundation

/// A discovery ping's public projection. Network endpoints never leave the wrapper.
public struct TailcatPing: Sendable, Equatable {
    public enum Path: Sendable, Equatable {
        case direct
        case relayed(regionID: Int, regionCode: String)
    }
    /// Round-trip latency in seconds. Zero is valid.
    public let latency: TimeInterval
    public let path: Path
    public init(latency: TimeInterval, path: Path) {
        self.latency = latency; self.path = path
    }

    static func decode(_ json: String?) throws -> TailcatPing {
        // Only this private, short-lived value can contain the direct endpoint.
        struct Reply: Decodable {
            let latency: Double
            let endpoint: String?
            let derp_region_id: Int?
            let derp_region_code: String?
        }
        guard let json, let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)),
              reply.latency.isFinite, reply.latency >= 0 else {
            throw TailcatError(.failure, "client.ping")
        }
        if let endpoint = reply.endpoint, !endpoint.isEmpty {
            return TailcatPing(latency: reply.latency, path: .direct)
        }
        guard let id = reply.derp_region_id, id > 0,
              let code = reply.derp_region_code, !code.isEmpty,
              code.count <= 32, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw TailcatError(.failure, "client.ping")
        }
        return TailcatPing(latency: reply.latency, path: .relayed(regionID: id, regionCode: code))
    }
}

extension TailcatClient {
    /// Starts/registers the client if necessary, probes discovery and starts a direct-path
    /// search. Always bounded: discovery otherwise waits indefinitely for an absent peer.
    public func ping(timeout: Duration = .seconds(10)) async throws -> TailcatPing {
        guard timeout > .zero else { throw TailcatError(.invalidArgument, "client.ping") }
        let client = owned.handle
        let result = try await BlockingCall.run("client.ping", resource: client, timeout: timeout) { [owned] token in
            _ = owned
            var json: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_client_disco_ping(client, token, &json, &error)
            // Free both allocations on this call thread, including failed and late results.
            let text = takeCString(json)
            let message = takeCString(error)
            let value = status == statusOK ? try? TailcatPing.decode(text) : nil
            return CReturn(status: status, value: value, message: message)
        }
        guard result.status == statusOK else {
            throw TailcatError(status: result.status, operation: "client.ping", message: result.message, secrets: secrets)
        }
        guard let value = result.value else { throw TailcatError(.failure, "client.ping") }
        return value
    }
}
