#if os(macOS)
import AppKit

/// Writes to the general pasteboard for Copy. Every write names Catflap as its source
/// (nspasteboard.org's `org.nspasteboard.source`), and a pairing code is also marked
/// concealed, so clipboard managers, Catflap's own history included, leave it out.
@MainActor
enum PasteboardWriter {
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let source = "io.github.yigityazicilar.Catflap"

    static func write(text: String, concealed: Bool = false, to board: NSPasteboard = .general) {
        board.clearContents()
        let item = NSPasteboardItem()
        // The marker comes first: a watcher reads the types and can stop before any content.
        if concealed { item.setString("", forType: concealedType) }
        item.setString(source, forType: sourceType)
        item.setString(text, forType: .string)
        board.writeObjects([item])
    }

    static func write(files: [URL], to board: NSPasteboard = .general) {
        board.clearContents()
        let items = files.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(source, forType: sourceType)
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        board.writeObjects(items)
    }

    static func write(image data: Data, mime: String?, to board: NSPasteboard = .general) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(source, forType: sourceType)
        item.setData(data, forType: mime == "image/jpeg" ? NSPasteboard.PasteboardType("public.jpeg") : .png)
        board.writeObjects([item])
    }

    /// File URLs on `board`, for pasting files into the panel.
    static func files(on board: NSPasteboard = .general) -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.isFileURL)
    }
}
#endif
