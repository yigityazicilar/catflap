import Foundation

public struct AuditNeedle: Sendable {
    public let bytes: Data
    public let kind: String
    public let line: Int?
    public init(bytes: Data, kind: String, line: Int? = nil) { self.bytes = bytes; self.kind = kind; self.line = line }
}
public struct AuditFinding: Codable, Sendable, Hashable {
    public let file: String
    public let offset: UInt64
    public let kind: String
    public let line: Int?
}

/// Scans raw database/sidecar bytes as well as ordinary files. Only the exact contiguous
/// device-column run is exempt in SQLite files; an address elsewhere in the WAL is a leak.
public struct DiskAudit: Sendable {
    public let directory: URL
    public let inbox: URL
    public init(directory: URL, inbox: URL) { self.directory = directory; self.inbox = inbox }
    public func scan(needles: [AuditNeedle], devices: [DeviceRecord] = []) throws -> [AuditFinding] {
        let needles = needles.filter { !$0.bytes.isEmpty }
        let homes = devices.flatMap { device -> [Data] in
            let prefix = Data((device.clientPublicKey + device.address).utf8)
            return [prefix + Data(device.pairSecret.base64EncodedString().utf8), prefix + device.pairSecret]
        }
        let overlap = max(needles.map(\.bytes.count).max() ?? 1, homes.map(\.count).max() ?? 1) - 1
        var findings: Set<AuditFinding> = []
        var visited: Set<String> = []
        let dataPath = Self.canonical(directory)
        for (root, label) in [(directory, "data"), (inbox, "inbox")] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            // Walk the resolved folder: on Linux the enumerator does not follow a link given as
            // its root, and would report a clean scan of nothing.
            let rootPath = Self.canonical(root)
            let start = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { throw AgentError.storage }
            for case let file as URL in enumerator {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                // The enumerator may hand back a path that differs from the root's in an
                // ancestor link (macOS gives /private/var for /var), so every comparison and
                // every relative name uses the resolved form of both.
                let path = Self.canonical(file)
                guard visited.insert(path).inserted else { continue }
                #if os(Linux)
                if path == dataPath + "/keys.json" { continue }
                #endif
                let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : file.lastPathComponent
                var name = label + "/" + relative
                for needle in needles {
                    if let value = String(data: needle.bytes, encoding: .utf8) { name = name.replacingOccurrences(of: value, with: "<redacted>") }
                }
                let database = Self.canonical(file.deletingLastPathComponent()) == dataPath
                    && ["store.sqlite", "store.sqlite-wal", "store.sqlite-shm", "store.sqlite-journal"].contains(file.lastPathComponent)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var tail = Data(), consumed: UInt64 = 0, processed: UInt64 = 0
                while true {
                    let chunk = try handle.read(upToCount: max(1024 * 1024, overlap + 1)) ?? Data()
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
                            findings.insert(.init(file: name, offset: base + UInt64(range.lowerBound), kind: needle.kind, line: needle.line))
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
                            findings.insert(.init(file: name, offset: absolute, kind: needle.kind, line: needle.line))
                        }
                    }
                }
            }
        }
        return findings.sorted { ($0.file, $0.offset, $0.kind, $0.line ?? 0) < ($1.file, $1.offset, $1.kind, $1.line ?? 0) }
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
