#if os(macOS)
import AppKit
import CatflapCore
import Foundation

@MainActor
protocol ClipboardSource: AnyObject {
    var changeCount: Int { get }
    var offeredTypes: [String] { get }
    var passwordManagerFrontmost: Bool { get }
    var access: String { get }
    func content(type: String, kind: ClipboardKind, limit: Int) throws -> ClipboardContent
}

enum ClipboardReadFailure: Error { case changed, unavailable, oversize }

@MainActor
final class SystemClipboardSource: ClipboardSource {
    private let board: NSPasteboard
    init(board: NSPasteboard = .general) { self.board = board }
    var changeCount: Int { board.changeCount }
    var offeredTypes: [String] { (board.types ?? []).map(\.rawValue) }
    // Bundle identifiers, not display names: localized names must not change the gate.
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.dashlane.Dashlane", "org.keepassxc.keepassxc", "com.enpass.Enpass",
        "com.markmcguill.strongbox", "com.markmcguill.strongbox.mac"
    ]
    var passwordManagerFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(Self.passwordManagers.contains) ?? false
    }
    var access: String {
        switch board.accessBehavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "default"
        }
    }
    func content(type: String, kind: ClipboardKind, limit: Int) throws -> ClipboardContent {
        let count = board.changeCount
        let items = board.pasteboardItems ?? []
        // Inspect every item's types before reading any representation. A marker on a later
        // item protects the entire copy, including the ordinary-looking first item.
        let types = items.flatMap { $0.types.map(\.rawValue) }
        guard !ClipboardWatcher.isMarked(types, frontmost: passwordManagerFrontmost),
              board.changeCount == count else { throw ClipboardReadFailure.changed }
        let pasteboardType = NSPasteboard.PasteboardType(type)
        let data: Data
        if kind == .files {
            var references = Data()
            for item in items where item.types.contains(pasteboardType) {
                guard board.changeCount == count else { throw ClipboardReadFailure.changed }
                guard let part = item.data(forType: pasteboardType) else { throw ClipboardReadFailure.unavailable }
                guard part.count <= limit - references.count else { throw ClipboardReadFailure.oversize }
                if !references.isEmpty {
                    guard references.count < limit else { throw ClipboardReadFailure.oversize }
                    references.append(10)
                }
                guard part.count <= limit - references.count else { throw ClipboardReadFailure.oversize }
                references.append(part)
            }
            data = references
        } else {
            // AppKit exposes complete representations, not a byte stream or a size query.
            // Never decode, convert, retain or submit a representation above the limit.
            guard let representation = board.data(forType: pasteboardType) else { throw ClipboardReadFailure.unavailable }
            guard representation.count <= limit else { throw ClipboardReadFailure.oversize }
            data = representation
        }
        guard board.changeCount == count else { throw ClipboardReadFailure.changed }
        let mime = kind == .image ? (type == "public.png" ? "image/png" : "image/jpeg") : "text/plain"
        return ClipboardContent(kind: kind, data: data, mime: mime)
    }
}

@MainActor
final class ClipboardWatcher {
    private let source: any ClipboardSource
    private let history: ClipboardHistory
    private let runtime: AgentRuntime
    private var lastChange: Int
    private var lastStatus: PlatformStatus?
    init(source: any ClipboardSource, history: ClipboardHistory, runtime: AgentRuntime) {
        self.source = source; self.history = history; self.runtime = runtime
        // Do not collect a copy that predates this agent's capture session.
        lastChange = source.changeCount
    }
    static func isMarked(_ types: [String], frontmost: Bool) -> Bool {
        SecretFilter.isMarked(offeredTypes: types, passwordManagerFrontmost: frontmost)
            || types.contains("Pasteboard generator type")
    }
    func reportStatus() async {
        let access = source.access
        let status = PlatformStatus(desktop: "macos", clipboardCapture: access == "alwaysDeny" ? "failed" : "active",
                                    pasteboardAccess: access)
        if status != lastStatus {
            lastStatus = status
            await runtime.setPlatformStatus(status)
        }
    }
    func poll() async {
        await reportStatus()
        let count = source.changeCount
        guard count != lastChange else { return }
        lastChange = count
        let types = source.offeredTypes
        guard source.changeCount == count, !Task.isCancelled else { return }
        let marked = Self.isMarked(types, frontmost: source.passwordManagerFrontmost)
        let selection: (String, ClipboardKind)? = [
            ("public.file-url", .files), ("public.url", .url), ("public.png", .image),
            ("public.jpeg", .image), ("public.utf8-plain-text", .text)
        ].first { types.contains($0.0) }
        // Every copy invalidates a previous Keep candidate, even an unsupported one.
        let (type, kind) = selection ?? ("", .text)
        do {
            _ = try await history.ingest(offeredTypes: types, passwordManagerFrontmost: marked, kind: kind) {
                try await MainActor.run {
                    guard !Task.isCancelled, selection != nil, self.source.changeCount == count,
                          !Self.isMarked(self.source.offeredTypes, frontmost: self.source.passwordManagerFrontmost)
                    else { throw ClipboardReadFailure.changed }
                    let value = try self.source.content(type: type, kind: kind,
                        limit: kind == .image ? ClipboardHistory.imageLimit : ClipboardHistory.textLimit)
                    guard self.source.changeCount == count else { throw ClipboardReadFailure.changed }
                    return value
                }
            }
        } catch {
            // Unavailable, oversized and superseded copies are dropped once, without logging
            // their contents or retrying a read under an obsolete list of types.
        }
    }
    func run() async {
        while !Task.isCancelled {
            await poll()
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }
    }
}
#endif
