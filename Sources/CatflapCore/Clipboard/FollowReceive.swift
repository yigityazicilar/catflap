import Foundation
import Crypto

extension TransferService {
    /// An unset follow permission held only bytes in memory. Once answered, Keep can retain
    /// those bytes in the ordinary received row; refusal still means received, not discarded.
    func retainFollowed(deviceID: String, id: String, content: ClipboardContent) async throws {
        guard var row = try await history.record(deviceID: deviceID, id: id),
              row.direction == "received", row.status == "ok", row.intent == "follow" else { return }
        if !row.keep {
            if content.kind == .image { rememberImage(content.data, mime: content.mime ?? "image/png", key: deviceID + "/" + id) }
            else { rememberText(String(decoding: content.data, as: UTF8.self), key: deviceID + "/" + id) }
            return
        }
        if row.text != nil || row.path != nil { return }
        if content.kind != .image {
            row.text = String(data: content.data, encoding: .utf8)
            row.sha256 = hex(SHA256.hash(data: content.data))
            try await history.save(row)
            return
        }
        let target = try await currentInbox()
        try target.prepare()
        let recovery = TransferInbox.newRecoveryID()
        let part = target.recoveryPart(recovery)
        let handle = try target.createRecoveryPart(recovery)
        var published: URL?
        do {
            try handle.write(contentsOf: content.data); try handle.synchronize(); try handle.close()
            let ext = ImageKind.extensions[content.mime ?? ""] ?? "img"
            let name = try target.publishPart(recovery, as: "Clipboard image." + ext)
            let destination = try target.url(name)
            published = destination
            row.path = destination.path; row.targetName = name
            row.sha256 = hex(SHA256.hash(data: content.data))
            try await history.save(row)
            try FileManager.default.removeItem(at: part)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: part)
            if let published { try? FileManager.default.removeItem(at: published) }
            throw error
        }
    }
}
