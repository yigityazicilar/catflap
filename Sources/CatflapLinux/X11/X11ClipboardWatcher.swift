import CatflapCore
import CX11
import Foundation

/// Clipboard capture on X11. XFixes reports every change of the CLIPBOARD selection's owner,
/// also while Catflap has no window or focus. For each change the watcher first asks the new
/// owner for its TARGETS alone and hands their raw names to the history's gate; only a copy
/// the gate lets through is read. GTK's own X11 clipboard is not used: it hides
/// `x-kde-passwordManagerHint` from the formats it lists, so it cannot be the marker check.
///
/// The worker thread owns the X connection; a body read runs on a thread of its own while the
/// worker waits for it, so one thread uses the connection at a time. Only the wake pipe is
/// touched during stop. PRIMARY (the middle-click selection) is not watched.
final class X11ClipboardWatcher: @unchecked Sendable {
    private let history: ClipboardHistory
    private let runtime: AgentRuntime
    private let ended = DispatchGroup()
    private let wake: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var cancelled = false
    // Below: the worker's, or the reader's while the worker waits for it.
    private var display: OpaquePointer?
    private var window: Window = 0
    private var fixesEvent: Int32 = 0
    private var atoms: [String: Atom] = [:]
    /// A newer owner change seen while an older one was handled.
    private var newer: Change?

    private struct Change {
        let owner: Window
        let time: Time
    }

    /// How long one answer from the owner may take: its list of targets, a body, or each
    /// part of a body sent in increments.
    private static let answerLimit: Int32 = 3000

    init(history: ClipboardHistory, runtime: AgentRuntime) {
        self.history = history
        self.runtime = runtime
        var ends: [Int32] = [-1, -1]
        if pipe(&ends) == 0 {
            for end in ends {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            }
        } else {
            ends = [-1, -1]
        }
        wake = (ends[0], ends[1])
    }

    deinit {
        if wake.read >= 0 { close(wake.read); close(wake.write) }
    }

    func start() async {
        ended.enter()
        await withCheckedContinuation { ready in
            Thread.detachNewThread { [self] in
                run(ready: ready)
                ended.leave()
            }
        }
    }

    func stop() async {
        lock.withLock { cancelled = true }
        if wake.write >= 0 {
            var byte: UInt8 = 1
            _ = write(wake.write, &byte, 1)
        }
        await withCheckedContinuation { continuation in
            ended.notify(queue: .global()) { continuation.resume() }
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func publish(_ state: String) {
        let done = DispatchSemaphore(value: 0)
        let runtime = runtime
        Task {
            await runtime.updatePlatformStatus { $0.clipboardCapture = state }
            done.signal()
        }
        done.wait()
    }

    // MARK: The worker

    private func run(ready: CheckedContinuation<Void, Never>) {
        let state = open()
        publish(state)
        ready.resume()
        guard state == "active", let display else { closeDisplay(); return }
        let clipboard = atom("CLIPBOARD")
        // Whatever is on the clipboard when the agent starts counts as a copy, as the first
        // selection a Wayland data-control device reports does.
        let owner = XGetSelectionOwner(display, clipboard)
        var next: Change? = owner == Window(None) ? nil : Change(owner: owner, time: Time(CurrentTime))
        while !isCancelled {
            if next == nil {
                switch waitForChange() {
                case .change(let change): next = change
                case .cancelled: break
                case .failed: publish("failed")
                }
            }
            guard let change = next else { break }
            next = nil
            handle(change)
            next = newer
            newer = nil
        }
        closeDisplay()
    }

    /// `active`, `unsupported` (no XFixes) or `failed` (no X server answered).
    private func open() -> String {
        guard wake.read >= 0, let display = XOpenDisplay(nil) else { return "failed" }
        self.display = display
        // An owner that goes away mid-answer causes errors that belong to it, not to Catflap.
        X11Errors.ignore(display)
        var eventBase: Int32 = 0, errorBase: Int32 = 0
        var major: Int32 = 5, minor: Int32 = 0
        guard XFixesQueryExtension(display, &eventBase, &errorBase) != 0, XFixesQueryVersion(display, &major, &minor) != 0 else {
            return "unsupported"
        }
        fixesEvent = eventBase + XFixesSelectionNotify
        makeWindow()
        return "active"
    }

    /// The window answers arrive on. Never mapped.
    private func makeWindow() {
        guard let display else { return }
        if window != 0 { XDestroyWindow(display, window) }
        window = XCreateSimpleWindow(display, XDefaultRootWindow(display), -10, -10, 1, 1, 0, 0, 0)
        XSelectInput(display, window, PropertyChangeMask)
        XFixesSelectSelectionInput(display, window, atom("CLIPBOARD"),
                                   UInt(XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask
                                        | XFixesSelectionClientCloseNotifyMask))
        XFlush(display)
    }

    private func closeDisplay() {
        guard let display else { return }
        if window != 0 { XDestroyWindow(display, window) }
        window = 0
        XCloseDisplay(display)
        X11Errors.forget(display)
        self.display = nil
    }

    private func atom(_ name: String) -> Atom {
        if let known = atoms[name] { return known }
        guard let display else { return 0 }
        let value = XInternAtom(display, name, 0)
        atoms[name] = value
        return value
    }

    private enum Wait { case change(Change), cancelled, failed }

    private func waitForChange() -> Wait {
        while true {
            switch nextEvent(timeout: -1) {
            case .event(var event):
                if let change = change(in: &event) { return .change(change) }
            case .timedOut: continue
            case .cancelled: return .cancelled
            case .failed: return .failed
            }
        }
    }

    /// The owner change an XFixes event reports; the newest of any already queued behind it.
    private func change(in event: inout XEvent) -> Change? {
        guard event.type == fixesEvent else { return nil }
        let notify = withUnsafePointer(to: &event) {
            $0.withMemoryRebound(to: XFixesSelectionNotifyEvent.self, capacity: 1) { $0.pointee }
        }
        guard notify.selection == atom("CLIPBOARD") else { return nil }
        // An owner that quit leaves the clipboard empty.
        let owner = notify.subtype == XFixesSetSelectionOwnerNotify ? notify.owner : Window(None)
        return Change(owner: owner, time: notify.subtype == XFixesSetSelectionOwnerNotify ? notify.selection_timestamp : Time(CurrentTime))
    }

    private enum Next { case event(XEvent), timedOut, cancelled, failed }

    /// The next X event, waiting at most `timeout` milliseconds (-1: no limit) and ending at
    /// once when the watcher is stopped.
    private func nextEvent(timeout: Int32) -> Next {
        guard let display else { return .failed }
        let deadline = timeout < 0 ? nil : DispatchTime.now() + .milliseconds(Int(timeout))
        while true {
            if isCancelled { return .cancelled }
            if XPending(display) > 0 {
                var event = XEvent()
                XNextEvent(display, &event)
                return .event(event)
            }
            var remaining: Int32 = -1
            if let deadline {
                let now = DispatchTime.now()
                guard now < deadline else { return .timedOut }
                remaining = Int32((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000) + 1
            }
            var fds = [pollfd(fd: XConnectionNumber(display), events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
            let result = poll(&fds, 2, remaining)
            if result < 0 && errno != EINTR { return .failed }
            if fds[1].revents != 0 { return .cancelled }
            if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return .failed }
        }
    }

    /// Waits for the answer to a conversion of `target`. Nil if it was refused, timed out, the
    /// watcher stopped, or the clipboard changed owner first; the last is kept in `newer`.
    private func awaitAnswer(_ target: Atom) -> Atom? {
        let clipboard = atom("CLIPBOARD")
        while true {
            switch nextEvent(timeout: Self.answerLimit) {
            case .event(var event):
                if let change = change(in: &event) { newer = change; return nil }
                guard event.type == SelectionNotify else { continue }
                let answer = event.xselection
                guard answer.requestor == window, answer.selection == clipboard, answer.target == target else { continue }
                return answer.property == Atom(None) ? nil : answer.property
            case .timedOut, .cancelled, .failed:
                return nil
            }
        }
    }

    // MARK: One copy

    private func handle(_ change: Change) {
        guard change.owner != Window(None) else {
            ingest(types: [], change: change)
            return
        }
        guard let display else { return }
        let targets = atom("TARGETS"), property = atom("CATFLAP_SELECTION")
        XDeleteProperty(display, window, property)
        XConvertSelection(display, atom("CLIPBOARD"), targets, property, window, change.time)
        XFlush(display)
        var types: [String] = []
        if let answer = awaitAnswer(targets) {
            types = readAtoms(answer)
        } else if newer != nil {
            // A newer copy replaces this one before its targets were known.
            return
        }
        ingest(types: types, change: change)
    }

    private func readAtoms(_ property: Atom) -> [String] {
        guard let display else { return [] }
        var actual: Atom = 0
        var format: Int32 = 0
        var count: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        defer { if let data { XFree(data) } }
        guard XGetWindowProperty(display, window, property, 0, 1024, 1, Atom(AnyPropertyType), &actual, &format, &count, &after, &data) == Success,
              let data, format == 32 else { return [] }
        let items = UnsafeRawPointer(data).assumingMemoryBound(to: Atom.self)
        var names: [String] = []
        for index in 0..<Int(count) {
            guard items[index] != 0, let name = XGetAtomName(display, items[index]) else { continue }
            names.append(String(cString: name))
            XFree(name)
        }
        return names
    }

    private func ingest(types: [String], change: Change) {
        let representation = Self.representation(types)
        let done = DispatchSemaphore(value: 0)
        let history = history
        Task {
            do {
                // Every change reaches the gate, an empty clipboard too: it ends a pending
                // Keep, and the marker is checked before the reader is called.
                _ = try await history.ingest(offeredTypes: types, kind: representation?.kind ?? .text) { [self] in
                    guard let representation else { throw ClipboardFailure.invalid }
                    return try await read(representation, change: change)
                }
            } catch {
                // An owner that refused, stalled or changed records nothing. Neither content
                // nor the offered types belong in an error log.
            }
            done.signal()
        }
        done.wait()
    }

    private struct Representation: Sendable {
        let target: String
        let kind: ClipboardKind
        var limit: Int { kind == .image ? ClipboardHistory.imageLimit : ClipboardHistory.textLimit }
    }

    /// The same order as the Wayland watcher's: file references stay references, not reads of
    /// the files they name. X11 owners name UTF-8 text UTF8_STRING.
    private static func representation(_ types: [String]) -> Representation? {
        for target in ["text/uri-list", "image/png", "image/jpeg", "text/plain;charset=utf-8", "text/plain;charset=UTF-8",
                       "text/plain", "UTF8_STRING"] where types.contains(target) {
            return Representation(target: target, kind: target.hasPrefix("image/") ? .image : .text)
        }
        return nil
    }

    private func read(_ representation: Representation, change: Change) async throws -> ClipboardContent {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                // The worker waits for ingest while this runs, so the connection is this
                // thread's until it returns.
                guard let bytes = receive(representation, change: change) else {
                    continuation.resume(throwing: ClipboardFailure.invalid)
                    return
                }
                var data = bytes
                var kind = representation.kind
                if representation.target == "text/uri-list", data.count <= representation.limit {
                    guard let text = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: ClipboardFailure.invalid)
                        return
                    }
                    let entries = text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    if !entries.isEmpty && entries.allSatisfy({ URL(string: $0)?.isFileURL == true }) {
                        kind = .files
                    } else if entries.count == 1, let url = URL(string: entries[0]), ["http", "https"].contains(url.scheme) {
                        kind = .url
                    } else {
                        continuation.resume(throwing: ClipboardFailure.invalid)
                        return
                    }
                    data = Data(entries.joined(separator: "\n").utf8)
                }
                continuation.resume(returning: ClipboardContent(kind: kind, data: data, mime: representation.target))
            }
        }
    }

    /// The body in `representation`'s target, at most its limit plus one byte so the history
    /// can tell an oversize copy; nil if the owner refused, stalled or lost the clipboard.
    private func receive(_ representation: Representation, change: Change) -> Data? {
        guard let display, newer == nil else { return nil }
        let target = atom(representation.target), property = atom("CATFLAP_SELECTION")
        let capacity = representation.limit + 1
        XDeleteProperty(display, window, property)
        XConvertSelection(display, atom("CLIPBOARD"), target, property, window, change.time)
        XFlush(display)
        guard let answer = awaitAnswer(target) else { return nil }
        guard let first = take(answer, capacity: capacity) else { return nil }
        guard first.incremental else {
            return newer == nil && XGetSelectionOwner(display, atom("CLIPBOARD")) == change.owner ? first.bytes : nil
        }
        // INCR: the owner sends the body in parts, each once the previous one was deleted;
        // an empty part ends it.
        var body = Data()
        while true {
            guard let part = nextPart(answer, capacity: capacity - body.count) else {
                // An abandoned transfer must not write into the next one: a new window ends it.
                makeWindow()
                return nil
            }
            if part.isEmpty { break }
            body.append(part)
            if body.count >= capacity {
                makeWindow()
                break
            }
        }
        return newer == nil ? body : nil
    }

    /// Reads and deletes the property an answer was written to.
    private func take(_ property: Atom, capacity: Int) -> (bytes: Data, incremental: Bool)? {
        guard let display else { return nil }
        var actual: Atom = 0
        var format: Int32 = 0
        var count: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        defer { if let data { XFree(data) } }
        let units = (capacity + 3) / 4
        guard XGetWindowProperty(display, window, property, 0, units, 0, Atom(AnyPropertyType), &actual, &format, &count, &after, &data) == Success else {
            return nil
        }
        // Deleting the property is what asks an INCR owner for its first part.
        XDeleteProperty(display, window, property)
        XFlush(display)
        if actual == atom("INCR") { return (Data(), true) }
        guard let data, format == 8 else { return actual == Atom(None) ? nil : (Data(), false) }
        return (Data(bytes: data, count: min(Int(count), capacity)), false)
    }

    private func nextPart(_ property: Atom, capacity: Int) -> Data? {
        while true {
            switch nextEvent(timeout: Self.answerLimit) {
            case .event(var event):
                if let change = change(in: &event) { newer = change; return nil }
                guard event.type == PropertyNotify else { continue }
                let notify = event.xproperty
                guard notify.window == window, notify.atom == property, notify.state == PropertyNewValue else { continue }
                guard let part = take(property, capacity: max(capacity, 1)) else { return nil }
                return part.bytes
            case .timedOut, .cancelled, .failed:
                return nil
            }
        }
    }
}
