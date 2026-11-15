import CatflapCore
import Foundation
import Testing

/// `clip.list` over the real control socket with a normal history: several images near the
/// 20 MB limit, a long text and short ones. The list must answer with bounded previews and
/// `clip.get` with each full item, before and after a restart.
@Suite(.serialized) struct ClipboardControlTests {
    private struct Agent {
        let paths: AgentPaths
        let runtime: AgentRuntime
        let server: ControlServer
        let task: Task<Void, Never>
        func stop() async { server.stop(); await task.value; await runtime.stop() }
    }
    private func start(_ paths: AgentPaths) async throws -> Agent {
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        let runtime = try AgentRuntime(paths: paths)
        let store = await runtime.store
        let inbox = try TransferInbox(directory: paths.directory.appendingPathComponent("inbox"))
        let transfers = TransferService(store: store, inbox: inbox)
        let history = try await ClipboardHistory.open(store: store)
        try await ClipboardService(history: history, transfers: transfers, store: store, directory: paths.directory).install(on: runtime)
        try await runtime.start()
        let task = Task { await server.run { await runtime.handle($0) } }
        return Agent(paths: paths, runtime: runtime, server: server, task: task)
    }
    /// A request that could not be sent or answered, saying which and how large it was.
    private struct RequestFailed: Error, CustomStringConvertible { let description: String }
    private func request(_ command: String, _ arguments: [String: String] = [:], _ agent: Agent) async throws -> ControlResponse {
        do {
            return try await ControlClient.requestAsync(.init(command, arguments: arguments), socket: agent.paths.socket)
        } catch {
            let size = arguments.values.reduce(0) { $0 + $1.utf8.count }
            let said = (error as? AgentError)?.rawValue ?? String(describing: error)
            throw RequestFailed(description: "\(command) with \(size) bytes of arguments was not answered: \(said)")
        }
    }
    private func list(_ agent: Agent) async throws -> (payload: Data, items: [[String: Any]]) {
        let response = try await request("clip.list", [:], agent)
        try #require(response.ok, "clip.list failed: \(response.error ?? "")")
        let items = try #require(try JSONSerialization.jsonObject(with: response.payload) as? [[String: Any]])
        return (response.payload, items)
    }

    @Test func testNearLimitImagesListAsBoundedPreviewsAndGetReturnsEachWhole() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        var agent: Agent! = try await start(paths)
        defer { agent?.server.stop() }
        // Three images just under the limit, each different, so none is a duplicate.
        var images: [String: Data] = [:]
        for index in 0..<3 {
            var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
            bytes.append(Data(repeating: UInt8(65 + index), count: ClipboardHistory.imageLimit - 1_000 - bytes.count))
            let added = try await request("clip.add", ["kind": "image", "mime": "image/png", "data": bytes.base64EncodedString()], agent)
            try #require(added.ok, "clip.add failed: \(added.error ?? "")")
            images[try #require(try added.decode(ClipboardIngestResult.self).id)] = bytes
        }
        // A long text whose preview cut falls inside a three-byte character, with words only
        // at its end, beyond any preview.
        let long = "y" + String(repeating: "x€", count: 600_000) + " tail marker"
        let longID = try #require(try await request("clip.add", ["text": long], agent).decode(ClipboardIngestResult.self).id)
        let short = "a short ordinary copy"
        let shortID = try #require(try await request("clip.add", ["text": short], agent).decode(ClipboardIngestResult.self).id)

        for round in ["before restart", "after restart"] {
            let (payload, items) = try await list(agent)
            #expect(items.count == 5, "\(round)")
            // Bounded: no image body, and far less than one image.
            #expect(payload.count < 1_000_000, "\(round): clip.list payload is \(payload.count) bytes")
            let decoded = try ControlJSON.decoder.decode([ClipboardItem].self, from: payload)
            for item in items {
                let id = try #require(item["id"] as? String)
                let content = Data(base64Encoded: try #require(item["content"] as? String)) ?? Data()
                if let full = images[id] {
                    #expect(content.isEmpty, "\(round): an image body is in the list")
                    #expect(item["size"] as? Int == full.count)
                    #expect(item["truncated"] as? Bool == true)
                } else if id == longID {
                    #expect(item["size"] as? Int == long.utf8.count)
                    #expect(item["truncated"] as? Bool == true)
                    #expect(content.count < 64 * 1024)
                    let preview = try #require(String(data: content, encoding: .utf8), "\(round): the preview splits a character")
                    #expect(long.hasPrefix(preview) && !preview.isEmpty)
                } else {
                    #expect(id == shortID)
                    #expect(String(data: content, encoding: .utf8) == short)
                    #expect(item["truncated"] as? Bool == false)
                }
            }
            #expect(decoded.first { $0.id == shortID }?.text == short)
            // Each whole item, one at a time.
            for (id, bytes) in images {
                let got = try await request("clip.get", ["id": id], agent)
                try #require(got.ok, "\(round): clip.get failed: \(got.error ?? "")")
                let item = try got.decode(ClipboardItem.self)
                #expect(item.content == bytes && item.kind == .image && item.mime == "image/png", "\(round)")
            }
            let text = try await request("clip.get", ["id": longID], agent).decode(ClipboardItem.self)
            #expect(text.text == long, "\(round)")
            #expect(try await request("clip.get", ["id": "no-such-item"], agent).ok == false)
            if round == "before restart" {
                // The old server must be gone, its lock released and socket removed, before
                // the next one starts on the same folder.
                await agent.stop()
                agent = nil
                agent = try await start(paths)
            }
        }
        // Delete one image; the rest stay listed and retrievable.
        let gone = try #require(images.keys.first)
        #expect(try await request("clip.delete", ["id": gone], agent).ok)
        let after = try await list(agent).items
        #expect(after.count == 4 && !after.contains { $0["id"] as? String == gone })
        #expect(try await request("clip.get", ["id": gone], agent).ok == false)
        // Search still reads the whole text, beyond the preview.
        let found = try await request("clip.list", ["search": "TAIL MARKER"], agent)
        #expect(try ControlJSON.decoder.decode([ClipboardItem].self, from: found.payload).map(\.id) == [longID])
        await agent.stop()
    }
}
