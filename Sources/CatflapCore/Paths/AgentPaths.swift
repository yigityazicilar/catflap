import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum AgentError: String, Error, LocalizedError, Sendable {
    case unsafePath = "Data path must be an owner-controlled directory or regular file."
    case alreadyRunning = "An agent is already running for this data directory."
    case storage = "Cannot access the local store."
    case identity = "Cannot access the device identity."
    case control = "Cannot reach the agent control channel."
    case invalidRequest = "Invalid control request."
    case unsupported = "This command is not available yet."
    public var errorDescription: String? { rawValue }
}

public struct AgentPaths: Sendable {
    public let directory: URL
    public var database: URL { directory.appendingPathComponent("store.sqlite") }
    public var socket: URL { directory.appendingPathComponent("control.sock") }
    public var lock: URL { directory.appendingPathComponent("agent.lock") }
    public var identity: URL { directory.appendingPathComponent("identity.json") }
    public var keys: URL { directory.appendingPathComponent("keys.json") }

    public static var defaultDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catflap")
        #else
        if let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], base.hasPrefix("/") {
            return URL(fileURLWithPath: base).appendingPathComponent("catflap")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/catflap")
        #endif
    }

    public init(directory: URL = Self.defaultDirectory) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(self.directory.path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw AgentError.unsafePath }
        guard chmod(self.directory.path, 0o700) == 0 else { throw AgentError.unsafePath }
    }

    public static func secureFile(_ url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { throw AgentError.unsafePath }
    }

    public static func writePrivate(_ data: Data, to url: URL) throws {
        try secureFile(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError.unsafePath }
        defer { close(fd); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentError.storage }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw AgentError.storage }
    }
}

public final class AgentLock: @unchecked Sendable {
    private let fd: Int32
    public init(paths: AgentPaths) throws {
        try AgentPaths.secureFile(paths.lock)
        let descriptor = open(paths.lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AgentError.alreadyRunning
        }
        fd = descriptor
    }
    deinit { close(fd) }
}
