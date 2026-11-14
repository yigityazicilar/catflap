import CGtk
import Foundation

/// The system file picker, through GTK's file dialog, which uses the desktop portal's file
/// chooser where one runs (KDE's dialog on Plasma, GNOME's on GNOME). GTK thread only.
// Touched only on the GTK thread, like the panel itself.
final class FilePicker: @unchecked Sendable {
    private(set) var isOpen = false

    /// Lets the person choose files to attach. `done` gets file URIs, empty if cancelled.
    func openFiles(parent: OpaquePointer?, _ done: @escaping ([String]) -> Void) {
        let dialog = opaque(gtk_file_dialog_new())
        gtk_file_dialog_set_title(dialog, "Attach files")
        gtk_file_dialog_set_accept_label(dialog, "Attach")
        isOpen = true
        let box = Unmanaged.passRetained(PickCallback { [weak self] uris in self?.isOpen = false; done(uris) }).toOpaque()
        gtk_file_dialog_open_multiple(dialog, parent?.cast(), nil, { source, result, data in
            guard let data else { return }
            let callback = Unmanaged<PickCallback>.fromOpaque(data).takeRetainedValue()
            var uris: [String] = []
            if let source, let files = gtk_file_dialog_open_multiple_finish(OpaquePointer(source), result, nil) {
                for index in 0..<g_list_model_get_n_items(files) {
                    guard let file = g_list_model_get_item(files, index) else { continue }
                    if let uri = g_file_get_uri(OpaquePointer(file)) {
                        uris.append(String(cString: uri))
                        g_free(uri)
                    }
                    g_object_unref(file)
                }
                g_object_unref(UnsafeMutableRawPointer(files))
            }
            if let source { g_object_unref(UnsafeMutableRawPointer(source)) }
            callback.body(uris)
        }, box)
    }

    /// Lets the person choose a folder (the inbox). `done` gets its path, nil if cancelled.
    func chooseFolder(parent: OpaquePointer?, _ done: @escaping (String?) -> Void) {
        let dialog = opaque(gtk_file_dialog_new())
        gtk_file_dialog_set_title(dialog, "Choose the inbox folder")
        isOpen = true
        let box = Unmanaged.passRetained(PickCallback { [weak self] uris in
            self?.isOpen = false
            done(uris.first.flatMap { URL(string: $0)?.path })
        }).toOpaque()
        gtk_file_dialog_select_folder(dialog, parent?.cast(), nil, { source, result, data in
            guard let data else { return }
            let callback = Unmanaged<PickCallback>.fromOpaque(data).takeRetainedValue()
            var uris: [String] = []
            if let source, let file = gtk_file_dialog_select_folder_finish(OpaquePointer(source), result, nil) {
                if let uri = g_file_get_uri(file) { uris.append(String(cString: uri)); g_free(uri) }
                g_object_unref(UnsafeMutableRawPointer(file))
            }
            if let source { g_object_unref(UnsafeMutableRawPointer(source)) }
            callback.body(uris)
        }, box)
    }
}

final class PickCallback {
    let body: ([String]) -> Void
    init(_ body: @escaping ([String]) -> Void) { self.body = body }
}
