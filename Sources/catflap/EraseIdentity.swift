import ArgumentParser
import CatflapCore
import Foundation

func reportAgentError(_ error: Error) {
    let security = error as? IdentitySecurityError
    let message = (error as? AgentError)?.rawValue ?? (security == nil ? "Agent could not start." : AgentError.identity.rawValue)
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if let security {
        // A numeric diagnostic only: Security's free-form text is never logged.
        FileHandle.standardError.write(Data("\(security.status)\n".utf8))
        if security.isAuthenticationFailed {
            FileHandle.standardError.write(Data("macOS refused this copy of Catflap access to its stored keys. A copy signed differently from the one that stored them is refused this way.\n".utf8))
        }
    }
}

struct EraseIdentity: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "erase-identity", shouldDisplay: false)
    @Option(name: .long) var dataDir: String
    func run() throws {
        do {
            let paths = try AgentPaths(directory: URL(fileURLWithPath: dataDir))
            let lock = try AgentLock(paths: paths)
            try IdentityStore(paths: paths).erase()
            withExtendedLifetime(lock) {}
        } catch {
            reportAgentError(error)
            throw ExitCode.failure
        }
    }
}
