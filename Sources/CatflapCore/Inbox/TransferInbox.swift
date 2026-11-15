import Foundation
import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Why an inbox folder cannot be used.
public enum TransferInboxError: String, Error, LocalizedError, Sendable {
    case unsafe = "The inbox folder must belong to you and must not be writable by others."
    case notAFolder = "The inbox must be a folder."
    case notAbsolute = "The inbox must be an absolute path."
    public var errorDescription: String? { rawValue }
}

public struct TransferInbox: Sendable {
    public let directory: URL
    public init(directory: URL, create: Bool = true) throws {
        if create { try Self.prepare(directory) }
        self.directory = directory.resolvingSymlinksInPath()
    }
    public func prepare() throws { try Self.prepare(directory) }
    /// A folder Catflap makes is private (0700). One that exists already, such as the
    /// person's Downloads, keeps its mode, but must belong to the person and must not be
    /// writable by group or others, or someone else could plant or swap entries in it.
    public static func prepare(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw TransferInboxError.notAbsolute }
        var info = stat()
        if stat(path, &info) != 0 {
            guard errno == ENOENT else { throw TransferInboxError.unsafe }
            let parent = directory.standardizedFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw AgentError.storage }
            guard stat(path, &info) == 0 else { throw AgentError.storage }
            if info.st_uid == getuid() { _ = chmod(path, 0o700) }
            guard stat(path, &info) == 0 else { throw AgentError.storage }
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw TransferInboxError.notAFolder }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw TransferInboxError.unsafe }
    }
    /// Where received files go when the person has not chosen a folder.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Catflap")
    }
    /// The most UTF-8 bytes a cleaned name, and so every numbered alternative, may have.
    public static let nameLimit = 180
    public static func clean(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "item"
        var result = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "item" }
        while result.utf8.count > nameLimit { result.removeLast() }
        return result
    }
    public func url(_ name: String) throws -> URL {
        guard name == Self.clean(name), !name.isEmpty else { throw WireError.malformed }
        return directory.appendingPathComponent(name)
    }
    public func part(_ name: String) throws -> URL { try url(name).appendingPathExtension("part") }
    public func availableName(_ name: String, excluding: Set<String> = []) -> String {
        let clean = Self.clean(name)
        let (stem, ext) = Self.split(clean)
        var candidate = clean
        var number = 1
        while excluding.contains(candidate) || exists(candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + ".part").path) {
            candidate = Self.numbered(stem: stem, ext: ext, number: number); number += 1
        }
        return candidate
    }
    static func split(_ name: String) -> (stem: String, ext: String) {
        let source = URL(fileURLWithPath: name)
        let ext = source.pathExtension
        return (ext.isEmpty ? name : source.deletingPathExtension().lastPathComponent, ext)
    }
    /// `stem (n).ext` within `nameLimit` bytes. The suffix's bytes are reserved by shortening
    /// the stem, down to one character, and then the extension, a whole character at a time,
    /// so no character is ever split.
    static func numbered(stem: String, ext: String, number: Int) -> String {
        let suffix = " (\(number))"
        var stem = stem, ext = ext
        while stem.utf8.count + suffix.utf8.count + (ext.isEmpty ? 0 : ext.utf8.count + 1) > nameLimit {
            if stem.count > 1 { stem.removeLast() }
            else if !ext.isEmpty { ext.removeLast() }
            else { break }
        }
        return stem + suffix + (ext.isEmpty ? "" : "." + ext)
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
        try syncDirectory()
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

    // MARK: Parts named by a recovery id

    /// A random recovery id: 32 lower-case hex digits.
    public static func newRecoveryID() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }
    static func isRecoveryID<S: StringProtocol>(_ id: S) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// The recovery id in a name Catflap gives its own entries (`.catflap-<id>.part`,
    /// `.partdir`, `.manifest`), or nil for any other name, which is never touched.
    public static func recoveryID(inName name: String) -> String? {
        guard name.hasPrefix(".catflap-") else { return nil }
        for suffix in [".part", ".partdir", ".manifest"] where name.hasSuffix(suffix) {
            let id = name.dropFirst(".catflap-".count).dropLast(suffix.count)
            if isRecoveryID(id) { return String(id) }
        }
        return nil
    }
    public func recoveryPart(_ id: String) -> URL { directory.appendingPathComponent(".catflap-\(id).part") }
    public func staging(_ id: String) -> URL { directory.appendingPathComponent(".catflap-\(id).partdir") }
    public func sidecar(_ id: String) -> URL { directory.appendingPathComponent(".catflap-\(id).manifest") }

    /// A new, private part file; it must not exist yet.
    func createRecoveryPart(_ id: String) throws -> FileHandle {
        let fd = open(recoveryPart(id).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError.storage }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// The existing part, cut back to `length`: bytes past what was recorded as synced may be
    /// garbage after a crash. It must be a regular file of ours with one link.
    func reopenRecoveryPart(_ id: String, length: Int64) throws -> FileHandle {
        let fd = open(recoveryPart(id).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentError.storage }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1,
              Int64(info.st_size) >= length, ftruncate(fd, off_t(length)) == 0, lseek(fd, off_t(length), SEEK_SET) == off_t(length) else {
            close(fd); throw AgentError.storage
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// The part's link count, or nil when it is not there. Two or more: it was published.
    func linkCount(ofPart id: String) -> Int? {
        var info = stat()
        guard lstat(recoveryPart(id).path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return Int(info.st_nlink)
    }
    /// Links the part under `name`, or the first free numbered name, and returns that name.
    /// A link never replaces anything, a symlink included.
    func publishPart(_ id: String, as name: String) throws -> String {
        let clean = Self.clean(name)
        let (stem, ext) = Self.split(clean)
        var candidate = clean, number = 1
        while true {
            if link(recoveryPart(id).path, directory.appendingPathComponent(candidate).path) == 0 { break }
            guard errno == EEXIST, number < 10_000 else { throw AgentError.storage }
            candidate = Self.numbered(stem: stem, ext: ext, number: number); number += 1
        }
        try syncDirectory()
        return candidate
    }
    /// Publishes a staged folder under `name`, or the first free numbered name: the name is
    /// reserved with an empty folder, which the rename then replaces in one step. A crash
    /// between the two leaves that empty folder; nothing else is ever replaced.
    func publishStaging(_ id: String, as name: String) throws -> String {
        let clean = Self.clean(name)
        var candidate = clean, number = 1
        while true {
            if mkdir(directory.appendingPathComponent(candidate).path, 0o700) == 0 { break }
            guard errno == EEXIST, number < 10_000 else { throw AgentError.storage }
            candidate = Self.numbered(stem: clean, ext: "", number: number); number += 1
        }
        guard rename(staging(id).path, directory.appendingPathComponent(candidate).path) == 0 else {
            _ = rmdir(directory.appendingPathComponent(candidate).path)
            throw AgentError.storage
        }
        try syncDirectory()
        return candidate
    }
    /// Removes the part, staging folder and sidecar of `id`, whichever exist.
    func removeRecovery(_ id: String) {
        _ = unlink(recoveryPart(id).path)
        _ = unlink(sidecar(id).path)
        Self.removeTree(staging(id).path)
    }
    /// Removes a folder Catflap staged, without following any link in it.
    static func removeTree(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for name in names { removeTree(path + "/" + name) }
            }
            _ = rmdir(path)
        } else { _ = unlink(path) }
    }
    func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { defer { close(fd) }; guard fsync(fd) == 0 else { throw AgentError.storage } }
    }
}
