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
    /// How long a change may show no types, or lack its chosen representation, before it is
    /// let go. Tests shorten it.
    var settleWindow: Duration = .seconds(2)
    private var unsettled: (count: Int, since: ContinuousClock.Instant)?
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
    /// A writer clears the pasteboard, which moves the change count, before it writes, and
    /// from another process the write can land a poll or more later. Until then the change
    /// shows no types, or its chosen representation is missing. Such a change is looked at
    /// again on later polls within `settleWindow` instead of being lost; one that stays
    /// empty, such as an app that only cleared the pasteboard, is then let go.
    private func stillSettling(_ count: Int) -> Bool {
        let now = ContinuousClock.now
        guard let unsettled, unsettled.count == count else {
            unsettled = (count, now)
            return true
        }
        return now - unsettled.since < settleWindow
    }
    func poll() async {
        await reportStatus()
        let count = source.changeCount
        guard count != lastChange else { return }
        let types = source.offeredTypes
        guard source.changeCount == count, !Task.isCancelled else { return }
        if types.isEmpty, stillSettling(count) { return }
        let previous = lastChange
        lastChange = count
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
            unsettled = nil
        } catch {
            if case ClipboardReadFailure.unavailable = error, stillSettling(count) {
                // Declared but not written yet: look at this change again on the next poll.
                lastChange = previous
            } else {
                // Oversized, superseded and still-unavailable copies are dropped once, without
                // logging their contents or retrying a read under an obsolete list of types.
                unsettled = nil
            }
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
