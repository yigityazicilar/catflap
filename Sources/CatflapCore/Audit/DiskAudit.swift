import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct AuditNeedle: Sendable {
    public let bytes: Data
    public let kind: String
    public let line: Int?
    public init(bytes: Data, kind: String, line: Int? = nil) { self.bytes = bytes; self.kind = kind; self.line = line }
}
public struct AuditFinding: Codable, Sendable, Hashable {
    /// The file, under its folder's label (`data/…`, `inbox/…`, `pending-inbox/…`). Empty when
    /// the name cannot be shown without one of the scanned values; `fileIndex` then tells such
    /// files apart.
    public let file: String
    public let offset: UInt64
    public let kind: String
    public let line: Int?
    /// The file's place in the scan, counting from 1, given only when `file` is left empty.
    public let fileIndex: Int?
    enum CodingKeys: String, CodingKey {
        case file, offset, kind, line
        case fileIndex = "file_index"
    }
    init(file: String, offset: UInt64, kind: String, line: Int?, fileIndex: Int? = nil) {
        self.file = file; self.offset = offset; self.kind = kind; self.line = line; self.fileIndex = fileIndex
    }
}
/// The audit could not read everything it must scan, so it cannot say the disk is clean.
/// The sentence names no file and no value.
public enum DiskAuditError: String, Error, LocalizedError, Sendable {
    case incomplete = "The audit is incomplete: a file or folder it must scan cannot be read."
    public var errorDescription: String? { rawValue }
}

/// Scans raw database/sidecar bytes as well as ordinary files. Only the exact contiguous
/// device-column run is exempt in SQLite files; an address elsewhere in the WAL is a leak.
///
/// Every folder and file below each root is read, or the scan throws
/// `DiskAuditError.incomplete`: a folder that cannot be listed is never taken for an empty
/// one. Only an inbox that does not exist is passed over, because nothing was received into it.
public struct DiskAudit: Sendable {
    public let directory: URL
    /// The inbox the running receiver writes to.
    public let inbox: URL
    /// The inbox chosen for the next start, scanned as `pending-inbox/…` when it is another folder.
    public let pendingInbox: URL?
    public init(directory: URL, inbox: URL, pendingInbox: URL? = nil) {
        self.directory = directory; self.inbox = inbox; self.pendingInbox = pendingInbox
    }
    public func scan(needles: [AuditNeedle], devices: [DeviceRecord] = []) throws -> [AuditFinding] {
        let needles = needles.filter { !$0.bytes.isEmpty }
        let homes = devices.flatMap { device -> [Data] in
            let prefix = Data((device.clientPublicKey + device.address).utf8)
            return [prefix + Data(device.pairSecret.base64EncodedString().utf8), prefix + device.pairSecret]
        }
        let overlap = max(needles.map(\.bytes.count).max() ?? 1, homes.map(\.count).max() ?? 1) - 1
        var findings: Set<AuditFinding> = []
        var visited: Set<[UInt8]> = []
        var index = 0
        let dataPath = Array(Self.canonical(directory).utf8)
        let databaseFiles = Set(["store.sqlite", "store.sqlite-wal", "store.sqlite-shm", "store.sqlite-journal"].map { Array($0.utf8) })
        var roots: [(url: URL, label: String, required: Bool)] = [(directory, "data", true), (inbox, "inbox", false)]
        if let pendingInbox, Self.canonical(pendingInbox) != Self.canonical(inbox) { roots.append((pendingInbox, "pending-inbox", false)) }
        for root in roots {
            // Walk the resolved folder: names are relative to it, and on Linux a link given as
            // the root would otherwise not be followed.
            let rootPath = Array(Self.canonical(root.url).utf8)
            var info = stat()
            if Self.withPath(rootPath, { stat($0, &info) }) != 0 {
                // Missing is not unreadable: a folder that cannot be reached fails the scan.
                guard !root.required, errno == ENOENT else { throw DiskAuditError.incomplete }
                continue
            }
            try Self.walk(rootPath) { path, parent, leaf in
                guard visited.insert(path).inserted else { return }
                #if os(Linux)
                if parent == dataPath && leaf == Array("keys.json".utf8) { return }
                #endif
                index += 1
                let relative = String(decoding: path.dropFirst(rootPath.count + 1), as: UTF8.self)
                let (name, fileIndex) = Self.shown(root.label + "/" + relative, index: index, needles: needles)
                let database = parent == dataPath && databaseFiles.contains(leaf)
                let fd = Self.withPath(path) { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                if fd < 0 {
                    // Gone since its folder was listed: nothing is left to hold a value.
                    if errno == ENOENT { return }
                    throw DiskAuditError.incomplete
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var tail = Data(), consumed: UInt64 = 0, processed: UInt64 = 0
                while true {
                    let chunk: Data
                    do { chunk = try handle.read(upToCount: max(1024 * 1024, overlap + 1)) ?? Data() }
                    catch { throw DiskAuditError.incomplete }
                    if chunk.isEmpty { break }
                    let base = consumed - UInt64(tail.count)
                    let bytes = tail + chunk
                    let allowed: [Range<Int>] = database ? homes.flatMap { Self.ranges(of: $0, in: bytes) } : []
                    for needle in needles {
                        for range in Self.ranges(of: needle.bytes, in: bytes) {
                            if allowed.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }) { continue }
                            // Defer the overlap suffix to the next window so a device run split
                            // across two chunks is recognized before classifying its needles.
                            if base + UInt64(range.lowerBound) < processed || range.lowerBound >= bytes.count - overlap { continue }
                            findings.insert(.init(file: name, offset: base + UInt64(range.lowerBound), kind: needle.kind, line: needle.line, fileIndex: fileIndex))
                        }
                    }
                    consumed += UInt64(chunk.count)
                    processed = consumed > UInt64(overlap) ? consumed - UInt64(overlap) : 0
                    tail = Data(bytes.suffix(2 * overlap))
                }
                let base = consumed - UInt64(tail.count)
                // Final overlap has no following chunk.
                let allowed = database ? homes.flatMap { Self.ranges(of: $0, in: tail) } : []
                for needle in needles {
                    for range in Self.ranges(of: needle.bytes, in: tail) {
                        if allowed.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }) { continue }
                        // A run beginning before the final tail was already evaluated in the
                        // preceding window; retain enough context to avoid partial-row matches.
                        let absolute = base + UInt64(range.lowerBound)
                        if absolute >= processed {
                            findings.insert(.init(file: name, offset: absolute, kind: needle.kind, line: needle.line, fileIndex: fileIndex))
                        }
                    }
                }
            }
        }
        return findings.sorted {
            ($0.file, $0.fileIndex ?? 0, $0.offset, $0.kind, $0.line ?? 0) < ($1.file, $1.fileIndex ?? 0, $1.offset, $1.kind, $1.line ?? 0)
        }
    }
    /// The name a finding shows: each text value replaced with a marker, but only when no
    /// value's bytes are left in the result, the marker's own letters included. Otherwise
    /// no name at all, and the file's index instead.
    private static func shown(_ name: String, index: Int, needles: [AuditNeedle]) -> (String, Int?) {
        var name = name
        for needle in needles {
            if let value = String(data: needle.bytes, encoding: .utf8) { name = name.replacingOccurrences(of: value, with: "<redacted>") }
        }
        let bytes = Data(name.utf8)
        return needles.contains { bytes.range(of: $0.bytes) != nil } ? ("", index) : (name, nil)
    }
    /// Calls `visit` with the path, its folder and its name, as raw bytes, for every regular
    /// file below `path`, in name order, without following links. A folder that cannot be
    /// listed or an entry that cannot be examined fails the walk; one that vanished meanwhile
    /// is passed over.
    private static func walk(_ path: [UInt8], _ visit: ([UInt8], [UInt8], [UInt8]) throws -> Void) throws {
        guard let folder = withPath(path, { opendir($0) }) else {
            if errno == ENOENT { return }
            throw DiskAuditError.incomplete
        }
        var names: [[UInt8]] = []
        do {
            defer { closedir(folder) }
            while true {
                errno = 0
                guard let entry = readdir(folder) else {
                    guard errno == 0 else { throw DiskAuditError.incomplete }
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix { $0 != 0 }) }
                if name != [46] && name != [46, 46] { names.append(name) }
            }
        }
        for name in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let child = path + [47] + name
            var info = stat()
            guard withPath(child, { lstat($0, &info) }) == 0 else {
                if errno == ENOENT { continue }
                throw DiskAuditError.incomplete
            }
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) { try walk(child, visit) }
            else if type == mode_t(S_IFREG) { try visit(child, path, name) }
        }
    }
    private static func withPath<T>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        (path + [0]).withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
        }
    }
    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static func ranges(of needle: Data, in data: Data) -> [Range<Int>] {
        guard !needle.isEmpty, data.count >= needle.count else { return [] }
        var result: [Range<Int>] = [], start = 0
        while start <= data.count - needle.count, let range = data.range(of: needle, in: start..<data.count) {
            result.append(range); start = range.lowerBound + 1
        }
        return result
    }
}
