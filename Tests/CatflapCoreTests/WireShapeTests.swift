import CatflapCore
import Crypto
import Foundation
import Testing

/// Every frame's key set is pinned under the protocol version it belongs to, so a field
/// change without a version bump fails here. `WireShapesFixture` is append-only: a
/// new version adds its own entry and leaves the older ones.
@Suite struct WireShapeTests {
    static func shapes() throws -> [String: [String]] {
        let entry = ManifestEntry(path: ["a"], type: "file", size: 1, sha256: String(repeating: "0", count: 64))
        let frames: [Data] = [
            try WireCodec.frame(Hello(v: WireProtocol.version, deviceID: "d", build: "b", nonce: "n")),
            try WireCodec.frame(Challenge(nonce: "n")),
            try WireCodec.frame(Auth(hmac: "h")),
            try WireCodec.frame(OK(hmac: "h")),
            try WireCodec.frame(Mismatch(v: 1, build: "b")),
            try WireCodec.frame(TransferOffer(id: "i", kind: "folder", name: "n", size: 1, mime: "m", keep: true, sha256: "s",
                                              intent: "follow", clipKind: "url", entries: 1, skipped: 0)),
            try WireCodec.frame(TransferAccept(offset: 0)),
            try WireCodec.frame(TransferHold()),
            try WireCodec.frame(WantManifest()),
            try WireCodec.frame(ManifestFrame(first: 0, entries: [entry])),
            try WireCodec.frame(ManifestEnd(count: 1)),
            try WireCodec.frame(TransferReject(.folderLimits, limit: "entries")),
            try WireCodec.frame(TransferDone(sha256: "s")),
            try WireCodec.frame(TransferAbort(reason: "cancelled")),
            try WireCodec.frame(TransferAck(storedAs: "n")),
            try WireCodec.frame(TransferForget(ids: ["i"])),
            try WireCodec.frame(TransferForgotten(count: 1)),
        ]
        var result: [String: [String]] = [:]
        for data in frames {
            var decoder = FrameDecoder(); decoder.append(data)
            let frame = try #require(try decoder.next())
            let object = try headerObject(frame.header)
            var keys = object.keys.sorted()
            // A manifest's entries are part of its shape.
            if let entries = object["entries"] as? [[String: Any]], let first = entries.first { keys += first.keys.sorted().map { "entries[]." + $0 } }
            result[frame.type] = keys
        }
        return result
    }

    @Test func testFrameShapesChangeOnlyWithAVersionBump() throws {
        let fixture = try JSONDecoder().decode([String: [String: [String]]].self, from: Data(WireShapesFixture.json.utf8))
        let current = try Self.shapes()
        let printed = String(decoding: try JSONEncoder.sortedPretty.encode(current), as: UTF8.self)
        let pinned = try #require(fixture[String(WireProtocol.version)], "no entry for version \(WireProtocol.version); this version's shapes:\n\(printed)")
        #expect(pinned == current, "frame shapes changed without a protocol version bump; this version's shapes:\n\(printed)")
        // Older entries are history: never a match for the current shapes.
        for (version, shapes) in fixture where version != String(WireProtocol.version) {
            #expect(shapes != current, "version \(version) has the same shapes as \(WireProtocol.version)")
        }
    }
}

extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
