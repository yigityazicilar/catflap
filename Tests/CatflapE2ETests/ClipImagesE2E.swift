import CatflapCore
import Foundation
import Testing

/// `catflap clip list` with several images near the 20 MB limit, then `clip get`, delete and
/// a restart: the list stays small and each item can still be had whole.
@Suite(.timeLimit(.minutes(10))) struct ClipImagesE2E {
    @Test func testNearLimitImagesListGetDeleteAndRestart() async throws {
        let agent = try AgentHarness(); defer { agent.stop() }
        try await onThread { try agent.start() }
        let folder = agent.dataDirectory.deletingLastPathComponent().appendingPathComponent("clip-images-" + UUID().uuidString)
        _ = try AgentPaths(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        var images: [String: Data] = [:]
        for index in 0..<3 {
            var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
            bytes.append(Data(repeating: UInt8(97 + index), count: ClipboardHistory.imageLimit - 1_000 - bytes.count))
            let file = folder.appendingPathComponent("image-\(index).png")
            try AgentPaths.writePrivate(bytes, to: file)
            let added = try await onThread { try agent.command(["clip", "add", "--kind", "image", "--file", file.path], timeout: 120) }
            // The output is this test's own fixture's result, never a secret.
            try #require(added.code == 0, "clip add of image \(index): status \(added.code), \(String(decoding: added.output.prefix(300), as: UTF8.self))")
            images[try #require(try added.decode(ClipboardIngestResult.self).id)] = bytes
        }
        let short = "an ordinary copy beside the images"
        let shortID = try #require(try await onThread { try agent.command(["clip", "add", "--text", short]) }.decode(ClipboardIngestResult.self).id)

        func listed() async throws -> [ClipboardItem] {
            let result = try await onThread { try agent.command(["clip", "list"], timeout: 120) }
            #expect(result.code == 0, "clip list: status \(result.code), \(String(decoding: result.output.prefix(200), as: UTF8.self))")
            #expect(result.output.count < 1_000_000, "clip list printed \(result.output.count) bytes")
            return try result.decode([ClipboardItem].self)
        }
        func whole(_ id: String) async throws -> ClipboardItem {
            let result = try await onThread { try agent.command(["clip", "get", id], timeout: 120) }
            #expect(result.code == 0, "clip get: status \(result.code)")
            return try result.decode(ClipboardItem.self)
        }
        for round in 0..<2 {
            let items = try await listed()
            #expect(Set(items.map(\.id)) == Set(images.keys).union([shortID]), "round \(round)")
            for item in items where item.kind == .image {
                #expect(item.content.isEmpty && item.size == images[item.id]?.count, "round \(round): an image is listed with its body")
            }
            #expect(items.first { $0.id == shortID }?.text == short)
            for (id, bytes) in images {
                let item = try await whole(id)
                #expect(item.content == bytes && item.mime == "image/png", "round \(round)")
            }
            if round == 0 { try await onThread { try agent.restart() } }
        }
        let gone = try #require(images.keys.sorted().first)
        #expect(try await onThread { try agent.command(["clip", "delete", gone]) }.code == 0)
        images[gone] = nil
        try await onThread { try agent.restart() }
        #expect(Set(try await listed().map(\.id)) == Set(images.keys).union([shortID]))
        let missing = try await onThread { try agent.command(["clip", "get", gone]) }
        #expect(missing.code == 1)
        #expect(jsonObject(missing.output)?["error"] as? String == ClipboardFailure.missing.rawValue)
    }
}
