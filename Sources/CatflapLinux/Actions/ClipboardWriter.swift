import CGtk
import CatflapCore
import Foundation

/// Puts content on the desktop's clipboard through GDK, the way any application's Copy does,
/// and reads a file list from it for pasting files into the panel. GTK thread only.
// Touched only on the GTK thread, like the panel itself.
final class ClipboardWriter: @unchecked Sendable {
    /// The marker KDE's and GNOME's clipboard histories read as "do not record this copy".
    static let secretMarker = "x-kde-passwordManagerHint"

    private var clipboard: OpaquePointer? {
        guard let display = gdk_display_get_default() else { return nil }
        return gdk_display_get_clipboard(display)
    }
    /// Counts what this writer put on the clipboard. A whole item fetched after a later Copy
    /// started must not replace that later one.
    private var generation = 0

    func set(text: String, secret: Bool = false) {
        var providers = [Self.provider(Data(text.utf8), "text/plain;charset=utf-8"), Self.provider(Data(text.utf8), "text/plain")]
        if secret { providers.append(Self.provider(Data("secret".utf8), Self.secretMarker)) }
        set(providers)
    }

    /// File URIs, as file managers put them.
    func set(files uris: [String]) {
        let list = Data(uris.joined(separator: "\r\n").utf8)
        let paths = Data(uris.compactMap { URL(string: $0)?.path }.joined(separator: "\n").utf8)
        set([Self.provider(list, "text/uri-list"), Self.provider(paths, "text/plain;charset=utf-8")])
    }

    /// A clipboard history item as it was copied. The panel's list holds previews, without an
    /// image's bytes and with only the start of a long text; such an item is fetched whole
    /// with `clip.get` first, and written when it arrives unless another Copy came after it.
    func set(_ item: ClipboardItem) {
        generation &+= 1
        guard item.truncated else { write(item); return }
        guard let runtime = AgentRuntime.process else { return }
        let ticket = generation, id = item.id
        Task { [weak self] in
            let response = await runtime.handle(ControlRequest("clip.get", arguments: ["id": id]))
            guard response.ok, let whole = try? response.decode(ClipboardItem.self), !whole.truncated else { return }
            GLib.idle { [weak self] in
                guard let self, self.generation == ticket else { return }
                self.write(whole)
            }
        }
    }

    private func write(_ item: ClipboardItem) {
        switch item.kind {
        case .text: set(text: item.text ?? "")
        case .url:
            let text = item.text ?? ""
            set([Self.provider(Data(text.utf8), "text/uri-list"), Self.provider(Data(text.utf8), "text/plain;charset=utf-8")])
        case .files: set(files: (item.text ?? "").split(whereSeparator: \.isNewline).map(String.init))
        case .image: set([Self.provider(item.content, item.mime ?? "image/png")])
        }
    }

    /// A secret the person asked to copy (the pairing code): marked so no history records it.
    func set(secret text: String) { set(text: text, secret: true) }

    private static func provider(_ data: Data, _ mime: String) -> UnsafeMutablePointer<GdkContentProvider> {
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        return gdk_content_provider_new_for_bytes(mime, bytes)!
    }

    private func set(_ providers: [UnsafeMutablePointer<GdkContentProvider>]) {
        generation &+= 1
        guard let clipboard else { return }
        var list: [UnsafeMutablePointer<GdkContentProvider>?] = providers
        let union = list.withUnsafeMutableBufferPointer { buffer in
            gdk_content_provider_new_union(buffer.baseAddress, gsize(buffer.count))
        }
        _ = gdk_clipboard_set_content(clipboard, union)
        g_object_unref(UnsafeMutableRawPointer(union))
    }

    /// Reads the files on the clipboard as file URIs and calls `done` on the GTK thread.
    static func readFiles(_ clipboard: OpaquePointer, _ done: @escaping ([String]) -> Void) {
        let box = Unmanaged.passRetained(FilesCallback(done)).toOpaque()
        gdk_clipboard_read_value_async(clipboard, gdk_file_list_get_type(), 0, nil, { source, result, data in
            guard let data else { return }
            let callback = Unmanaged<FilesCallback>.fromOpaque(data).takeRetainedValue()
            var uris: [String] = []
            if let source, let value = gdk_clipboard_read_value_finish(OpaquePointer(source), result, nil),
               let boxed = g_value_get_boxed(value) {
                var node = gdk_file_list_get_files(OpaquePointer(boxed))
                let head = node
                while let current = node {
                    if let file = current.pointee.data, let uri = g_file_get_uri(OpaquePointer(file)) {
                        uris.append(String(cString: uri))
                        g_free(uri)
                    }
                    node = current.pointee.next
                }
                g_slist_free(head)
            }
            callback.body(uris)
        }, box)
    }
}

final class FilesCallback {
    let body: ([String]) -> Void
    init(_ body: @escaping ([String]) -> Void) { self.body = body }
}
