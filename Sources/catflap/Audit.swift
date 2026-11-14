import ArgumentParser
import CatflapCore
import Foundation

struct Audit: AsyncParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    @Option(name: .long, help: "Also scan for each line of this file; values are never printed.") var also: String?
    static func install(on runtime: AgentRuntime) async throws { await AuditService(runtime: runtime).install() }
    func run() async throws {
        var arguments: [String: String] = [:]
        if let also {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: also)); defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                guard bytes.count <= 4 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else {
                    try fail("Audit input must be a UTF-8 file of at most 4 MiB.", code: 1)
                }
                arguments["also"] = text.replacingOccurrences(of: "\r\n", with: "\n")
            } catch is ExitCode { throw ExitCode.failure }
            catch { try fail("Cannot read audit input file.", code: 1) }
        }
        var progress = try await request(.init("audit", arguments: arguments)).decode(AuditProgress.self)
        let deadline = ContinuousClock.now + .seconds(3600)
        while progress.status == "running", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            progress = try await request(.init("audit.status", arguments: ["id": progress.id])).decode(AuditProgress.self)
        }
        guard let findings = progress.findings else { try fail(progress.error ?? "Audit did not finish within an hour.", code: 1) }
        print(try ControlJSON.text(findings))
        if !findings.isEmpty { throw ExitCode.failure }
    }
    private func request(_ request: ControlRequest) async throws -> ControlResponse {
        let response: ControlResponse
        do { response = try await ControlClient.requestAsync(request, socket: options.socket) }
        catch { try fail(AgentError.control.rawValue, code: 1) }
        guard response.ok else { try fail(response.error ?? "Control request failed.", code: response.exitCode) }
        return response
    }
    private func fail(_ message: String, code: Int32) throws -> Never {
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(code)
    }
}
