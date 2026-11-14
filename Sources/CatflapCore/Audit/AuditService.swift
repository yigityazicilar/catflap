import Foundation

public struct AuditProgress: Codable, Sendable {
    public let id: String
    public let status: String
    public let findings: [AuditFinding]?
    public let error: String?
}
public actor AuditService {
    private let runtime: AgentRuntime
    private var jobs: [String: AuditProgress] = [:]
    public init(runtime: AgentRuntime) { self.runtime = runtime }
    public func install() async {
        await runtime.provide(self)
        await runtime.register("audit") { [self] request in
            // No path from an untrusted peer reaches here; this is the owner-only control API.
            let extras = request.arguments["also"]?.components(separatedBy: "\n") ?? []
            guard extras.count <= 10_000, extras.allSatisfy({ $0.utf8.count <= 64 * 1024 }) else {
                return ControlResponse(failure: "Audit strings are too large.")
            }
            return try await ControlResponse(value: start(extras: extras))
        }
        await runtime.register("audit.status") { [self] request in
            guard let id = request.arguments["id"], let job = await progress(id) else { return ControlResponse(failure: "Audit not found.") }
            return try ControlResponse(value: job)
        }
    }
    private func progress(_ id: String) -> AuditProgress? { jobs[id] }
    private func start(extras: [String]) -> AuditProgress {
        let id = UUID().uuidString
        if jobs.count >= 16 { jobs = jobs.filter { $0.value.status == "running" } }
        let progress = AuditProgress(id: id, status: "running", findings: nil, error: nil)
        jobs[id] = progress
        Task { [self] in
            do {
                let findings = try await run(extras: extras)
                jobs[id] = .init(id: id, status: "done", findings: findings, error: nil)
            } catch { jobs[id] = .init(id: id, status: "failed", findings: nil, error: "Cannot scan all audit files.") }
        }
        return progress
    }
    public func run(extras: [String]) async throws -> [AuditFinding] {
        let store = await runtime.store
        let identityServer = await runtime.identityServer
        let identity = await identityServer.identity
        var needles: [AuditNeedle] = []
        for keys in [identity.serverKeys, identity.clientKeys] {
            for key in [keys.privateKey, keys.publicKey, keys.presharedKey] {
                needles.append(.init(bytes: Data(key.utf8), kind: "key"))
                if let raw = Data(base64Encoded: key) { needles.append(.init(bytes: raw, kind: "key")) }
            }
        }
        if let address = try await identityServer.address() { needles.append(.init(bytes: Data(address.utf8), kind: "address")) }
        let devices = try await store.devices()
        for device in devices {
            needles.append(.init(bytes: Data(device.clientPublicKey.utf8), kind: "key"))
            if let raw = Data(base64Encoded: device.clientPublicKey) { needles.append(.init(bytes: raw, kind: "key")) }
            needles.append(.init(bytes: Data(device.address.utf8), kind: "address"))
            needles.append(.init(bytes: device.pairSecret, kind: "pair_secret"))
            needles.append(.init(bytes: Data(device.pairSecret.base64EncodedString().utf8), kind: "pair_secret"))
        }
        for (index, line) in extras.enumerated() where !line.isEmpty {
            needles.append(.init(bytes: Data(line.utf8), kind: "extra", line: index + 1))
        }
        let paths = await store.paths
        let configured = try await store.setting("inbox")
        let inbox = configured.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Catflap")
        let scanner = DiskAudit(directory: paths.directory, inbox: inbox)
        // Filesystem scanning is synchronous and can include multi-gigabyte inbox files.
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [needles] in continuation.resume(with: Result { try scanner.scan(needles: needles, devices: devices) }) }
        }
    }
}
