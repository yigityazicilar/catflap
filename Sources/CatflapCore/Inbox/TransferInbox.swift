import Foundation
import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct TransferInbox: Sendable {
    public let directory: URL
    public init(directory: URL, create: Bool = true) throws {
        if create { try Self.prepare(directory) }
        self.directory = directory.resolvingSymlinksInPath()
    }
    public func prepare() throws { try Self.prepare(directory) }
    private static func prepare(_ directory: URL) throws {
        _ = try AgentPaths(directory: directory)
    }
    public static func clean(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "item"
        var result = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "item" }
        while result.utf8.count > 180 { result.removeLast() }
        return result
    }
    public func url(_ name: String) throws -> URL {
        guard name == Self.clean(name), !name.isEmpty else { throw WireError.malformed }
        return directory.appendingPathComponent(name)
    }
    public func part(_ name: String) throws -> URL { try url(name).appendingPathExtension("part") }
    public func availableName(_ name: String, excluding: Set<String> = []) -> String {
        let clean = Self.clean(name)
        let source = URL(fileURLWithPath: clean)
        let ext = source.pathExtension
        let stem = ext.isEmpty ? clean : source.deletingPathExtension().lastPathComponent
        var candidate = clean
        var number = 1
        while excluding.contains(candidate) || exists(candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + ".part").path) {
            candidate = stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext); number += 1
        }
        return candidate
    }
    public func exists(_ name: String) -> Bool {
        guard let url = try? url(name) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    public func createPart(_ name: String) throws -> FileHandle {
        let p = try part(name)
        let fd = open(p.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentError.storage }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// A hard link publishes the file atomically and refuses even a symlink at the target.
    public func publish(_ name: String) throws {
        let p = try part(name); let final = try url(name)
        guard link(p.path, final.path) == 0 else { throw AgentError.storage }
        guard unlink(p.path) == 0 else { throw AgentError.storage }
        let fd = open(directory.path, O_RDONLY)
        if fd >= 0 { defer { close(fd) }; guard fsync(fd) == 0 else { throw AgentError.storage } }
    }
    public func removePart(_ name: String) throws {
        let p = try part(name)
        if unlink(p.path) != 0 && errno != ENOENT { throw AgentError.storage }
    }
    public func freeBytes() throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let number = attributes[.systemFreeSize] as? NSNumber else { throw AgentError.storage }
        return number.int64Value
    }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
