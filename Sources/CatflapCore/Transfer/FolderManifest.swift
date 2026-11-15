import Crypto
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The limits a folder transfer is held to, on both sides.
public struct FolderLimits: Sendable {
    public var entries = 10_000
    public var depth = 32
    public var component = TransferInbox.nameLimit
    public var path = 1024
    public var manifestBytes = 4 * 1024 * 1024
    public init() {}
}

/// Which folder limit a folder broke; the raw value is the wire's `limit`.
public enum FolderLimitError: String, Error, Sendable {
    case entries, depth, name, path, size, manifest
    public var sentence: String {
        switch self {
        case .entries: "The folder has more than 10,000 entries."
        case .depth: "The folder is nested more than 32 levels deep."
        case .name: "A name in the folder is longer than 180 bytes."
        case .path: "A path in the folder is longer than 1,024 bytes."
        case .size: "The folder is too large to send."
        case .manifest: "The folder's list of entries is too large."
        }
    }
}

/// What a file looked like when it was listed, to tell whether it changed since.
public struct SourceStat: Codable, Sendable, Equatable {
    public let size: Int64
    public let mtimeNs: Int64
    public let device: Int64
    public let inode: Int64
    init(_ info: stat) {
        size = Int64(info.st_size)
        #if os(Linux)
        mtimeNs = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
        #else
        mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #endif
        device = Int64(info.st_dev)
        inode = Int64(bitPattern: UInt64(info.st_ino))
    }
}

/// A folder as the sender lists it: regular files and folders below the chosen root, in
/// depth-first order with names sorted bytewise and each folder before its children.
/// Symlinks, special files and unreadable entries are left out and listed in `skipped`.
public struct FolderManifest: Codable, Sendable {
    public let entries: [ManifestEntry]
    public let skipped: [SkippedEntry]
    /// Per file entry, in order: what it looked like when listed.
    public let stats: [SourceStat]
    /// The `manifest` frames exactly as they are sent, length prefixes included.
    public let frames: Data
    /// SHA-256 over `frames`: the offer's `sha256` for a folder.
    public let digest: String
    public var totalSize: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Lists and hashes `root`. Throws `FolderLimitError` for a folder over the limits.
    public static func scan(_ root: URL, limits: FolderLimits = .init(), maxBytes: Int64) throws -> FolderManifest {
        let base = root.resolvingSymlinksInPath().path
        var entries: [ManifestEntry] = [], skipped: [SkippedEntry] = [], stats: [SourceStat] = []
        var total: Int64 = 0
        func walk(_ components: [String]) throws {
            let folder = ([base] + components).joined(separator: "/")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                throw AgentError.storage
            }
            for name in names.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let path = components + [name]
                let full = folder + "/" + name
                var info = stat()
                guard lstat(full, &info) == 0 else { skipped.append(.init(path: path, reason: "unreadable")); continue }
                let type = info.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFLNK) { skipped.append(.init(path: path, reason: "symlink")); continue }
                guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else { skipped.append(.init(path: path, reason: "special")); continue }
                guard path.count <= limits.depth else { throw FolderLimitError.depth }
                guard name.utf8.count <= limits.component else { throw FolderLimitError.name }
                guard path.joined(separator: "/").utf8.count <= limits.path else { throw FolderLimitError.path }
                if type == mode_t(S_IFDIR) {
                    guard access(full, R_OK | X_OK) == 0, (try? FileManager.default.contentsOfDirectory(atPath: full)) != nil else {
                        skipped.append(.init(path: path, reason: "unreadable")); continue
                    }
                    entries.append(.init(path: path, type: "dir"))
                    guard entries.count <= limits.entries else { throw FolderLimitError.entries }
                    try walk(path)
                } else {
                    let fd = open(full, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { skipped.append(.init(path: path, reason: "unreadable")); continue }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var opened = stat()
                    guard fstat(fd, &opened) == 0, (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                        skipped.append(.init(path: path, reason: "special")); continue
                    }
                    var hash = SHA256(), size: Int64 = 0
                    do {
                        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk); size += Int64(chunk.count) }
                    } catch { skipped.append(.init(path: path, reason: "unreadable")); continue }
                    total += size
                    guard total <= maxBytes else { throw FolderLimitError.size }
                    entries.append(.init(path: path, type: "file", size: size, sha256: hex(hash.finalize())))
                    stats.append(SourceStat(opened))
                    guard entries.count <= limits.entries else { throw FolderLimitError.entries }
                }
            }
        }
        try walk([])
        let frames = try encode(entries)
        guard frames.count <= limits.manifestBytes else { throw FolderLimitError.manifest }
        return FolderManifest(entries: entries, skipped: skipped, stats: stats, frames: frames, digest: hex(SHA256.hash(data: frames)))
    }

    /// The `manifest` frames for `entries`, each header at most 64 KiB.
    static func encode(_ entries: [ManifestEntry]) throws -> Data {
        var frames = Data(), first = 0
        while first < entries.count {
            var count = min(entries.count - first, 512)
            var header = try WireCodec.header(ManifestFrame(first: first, entries: Array(entries[first..<(first + count)])))
            while header.count > WireProtocol.maxHeader - 1024 && count > 1 {
                count = max(1, count / 2)
                header = try WireCodec.header(ManifestFrame(first: first, entries: Array(entries[first..<(first + count)])))
            }
            frames.append(try WireCodec.frame(header: header))
            first += count
        }
        return frames
    }

    /// Checks a received manifest against its offer and the limits. Throws
    /// `FolderLimitError` or `TransferFailure.invalid`.
    public static func validate(_ entries: [ManifestEntry], offer: TransferOffer, limits: FolderLimits = .init()) throws {
        guard entries.count <= limits.entries else { throw FolderLimitError.entries }
        guard entries.count == offer.entries else { throw TransferFailure.invalid }
        var folders: Set<[String]> = [], seen: Set<[String]> = [], total: Int64 = 0
        for entry in entries {
            guard !entry.path.isEmpty else { throw TransferFailure.invalid }
            guard entry.path.count <= limits.depth else { throw FolderLimitError.depth }
            for component in entry.path {
                guard !component.isEmpty, component != ".", component != "..",
                      !component.contains("/"), !component.contains("\\"), !component.unicodeScalars.contains("\0") else { throw TransferFailure.invalid }
                guard component.utf8.count <= limits.component else { throw FolderLimitError.name }
            }
            guard entry.path.joined(separator: "/").utf8.count <= limits.path else { throw FolderLimitError.path }
            guard seen.insert(entry.path).inserted else { throw TransferFailure.invalid }
            if entry.path.count > 1 { guard folders.contains(Array(entry.path.dropLast())) else { throw TransferFailure.invalid } }
            switch entry.type {
            case "dir":
                guard entry.size == nil, entry.sha256 == nil else { throw TransferFailure.invalid }
                folders.insert(entry.path)
            case "file":
                guard let size = entry.size, size >= 0, let sha = entry.sha256, isDigest(sha) else { throw TransferFailure.invalid }
                total += size
            default: throw TransferFailure.invalid
            }
        }
        guard total == offer.size else { throw TransferFailure.invalid }
    }

    /// The names entries get on disk: each component cleaned on its own (control characters
    /// and `:` dropped; leading dots kept inside the folder), and a name that clashes with an
    /// earlier one in the same folder, compared case- and normalization-insensitively, gets a
    /// number. Nothing is ever overwritten.
    public static func diskPaths(_ entries: [ManifestEntry]) -> [[String]] {
        var mapped: [[String]: [String]] = [:]
        var used: [[String]: Set<String>] = [:]
        var result: [[String]] = []
        for entry in entries {
            let parent = Array(entry.path.dropLast())
            let parentDisk = parent.isEmpty ? [] : (mapped[parent] ?? parent)
            var name = String(entry.path.last!.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
            if name.isEmpty || name == "." || name == ".." { name = "item" }
            let (stem, ext) = entry.type == "file" ? TransferInbox.split(name) : (name, "")
            var candidate = name, number = 1
            func key(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
            while used[parent, default: []].contains(key(candidate)) {
                candidate = TransferInbox.numbered(stem: stem, ext: ext, number: number); number += 1
            }
            used[parent, default: []].insert(key(candidate))
            let disk = parentDisk + [candidate]
            mapped[entry.path] = disk
            result.append(disk)
        }
        return result
    }

    /// The entries carried by `frames`, which must be `manifest` frames only.
    static func decode(frames: Data) throws -> [ManifestEntry] {
        var decoder = FrameDecoder(); decoder.append(frames)
        var entries: [ManifestEntry] = []
        while let frame = try decoder.next() {
            let part = try frame.decode(ManifestFrame.self)
            guard part.first == entries.count else { throw TransferFailure.invalid }
            entries += part.entries
        }
        guard decoder.bufferedCount == 0 else { throw TransferFailure.invalid }
        return entries
    }
}

func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
func isDigest(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

/// Writes a folder's entries below its staging folder, through folder descriptors opened
/// without following links: a link swapped into staging is refused, never followed.
struct FolderStager {
    let root: String
    let paths: [[String]]
    let entries: [ManifestEntry]

    /// Creates the staging folder and every folder entry; existing ones must be real folders.
    func prepareFolders() throws {
        if mkdir(root, 0o700) != 0 && errno != EEXIST { throw AgentError.storage }
        for (index, entry) in entries.enumerated() where entry.type == "dir" {
            let parent = try openFolder(Array(paths[index].dropLast()))
            defer { close(parent) }
            let name = paths[index].last!
            if mkdirat(parent, name, 0o700) != 0 {
                guard errno == EEXIST else { throw AgentError.storage }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw TransferFailure.invalid
                }
            }
        }
    }
    /// Opens the folder at `components` below the root, refusing a link anywhere on the way.
    func openFolder(_ components: [String]) throws -> Int32 {
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TransferFailure.invalid }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw TransferFailure.invalid }
            fd = next
        }
        return fd
    }
    /// The file entry at `index`, new, or the existing one cut to `length` to continue it.
    func openFile(_ index: Int, keeping length: Int64) throws -> FileHandle {
        let parent = try openFolder(Array(paths[index].dropLast()))
        defer { close(parent) }
        let name = paths[index].last!
        var fd: Int32
        if length == 0 {
            // A file a crash left past the synced length starts again.
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw TransferFailure.invalid }
                _ = unlinkat(parent, name, 0)
            }
            fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        } else {
            fd = openat(parent, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw TransferFailure.invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1, Int64(info.st_size) >= length,
              ftruncate(fd, off_t(length)) == 0, lseek(fd, off_t(length), SEEK_SET) == off_t(length) else {
            close(fd); throw TransferFailure.invalid
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// The SHA-256 state over the first `length` bytes of file entry `index`.
    func hashPrefix(_ index: Int, length: Int64) throws -> SHA256 {
        let parent = try openFolder(Array(paths[index].dropLast()))
        defer { close(parent) }
        let fd = openat(parent, paths[index].last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TransferFailure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256(), remaining = length
        while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty {
            hash.update(data: chunk); remaining -= Int64(chunk.count)
        }
        guard remaining == 0 else { throw TransferFailure.invalid }
        return hash
    }
}
