#if os(macOS)
@testable import CatflapMac
import AppKit
import CatflapCore
import Darwin
import Foundation
import Testing

private enum ActionsTestError: Error, CustomStringConvertible {
    case executableMissing, startup(String), timeout(String), decode(String), snapshot
    var description: String {
        switch self {
        case .executableMissing: "the catflap executable was not found"
        case .startup(let what): "agent did not start: \(what)"
        case .timeout(let what): "timed out waiting for \(what)"
        case .decode(let what): "could not decode \(what)"
        case .snapshot: "the pasteboard changed while it was saved"
        }
    }
}
private final class ActionsBundleMarker: NSObject {}

// Blocking process waits run on a thread of their own, never on Swift's cooperative pool.
private func actionsOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

// Foundation's unbounded wait can miss a child's exit on macOS: ask the kernel as well, and
// always stop at a deadline.
private func actionsWait(_ process: Process, seconds: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !process.isRunning { return process.terminationStatus }
        var info = siginfo_t()
        if waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
           info.si_pid == process.processIdentifier { return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
}

private struct ActionsCommand: Sendable {
    let code: Int32
    let output: Data
    let error: Data
    var text: String { String(decoding: output, as: UTF8.self) }
    var errorText: String { String(decoding: error, as: UTF8.self) }
}

private func actionsRun(_ tool: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                        in directory: URL, seconds: TimeInterval = 30) throws -> ActionsCommand {
    let outputURL = directory.appendingPathComponent(UUID().uuidString)
    let errorURL = directory.appendingPathComponent(UUID().uuidString)
    let inputURL = directory.appendingPathComponent(UUID().uuidString)
    for url in [outputURL, errorURL, inputURL] {
        FileManager.default.createFile(atPath: url.path, contents: url == inputURL ? input : nil, attributes: [.posixPermissions: 0o600])
    }
    defer { for url in [outputURL, errorURL, inputURL] { try? FileManager.default.removeItem(at: url) } }
    let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
    let source = try FileHandle(forReadingFrom: inputURL)
    defer { try? output.close(); try? error.close(); try? source.close() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: tool)
    child.arguments = arguments
    if let environment { child.environment = environment }
    child.standardOutput = output
    child.standardError = error
    child.standardInput = source
    try child.run()
    guard let code = actionsWait(child, seconds: seconds) else {
        kill(child.processIdentifier, SIGKILL); _ = actionsWait(child, seconds: 5)
        throw ActionsTestError.timeout(URL(fileURLWithPath: tool).lastPathComponent)
    }
    return ActionsCommand(code: code, output: try Data(contentsOf: outputURL), error: try Data(contentsOf: errorURL))
}

private func locateExecutable() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"] { return URL(fileURLWithPath: override) }
    var location = Bundle(for: ActionsBundleMarker.self).bundleURL
    for _ in 0..<7 {
        let candidate = location.appendingPathComponent("catflap")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        location.deleteLastPathComponent()
    }
    throw ActionsTestError.executableMissing
}

private func scratchDirectory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory.resolvingSymlinksInPath()
}

/// `ui state` on macOS: the panel's fields and this task's, read from one object.
private struct ActionsState: Decodable, Sendable {
    let ui: MacUIState
    let actions: MacActionState
    init(from decoder: any Decoder) throws {
        ui = try MacUIState(from: decoder)
        actions = try MacActionState(from: decoder)
    }
}

/// What this task's `ui invoke` actions answer.
private struct ActionsReply: Decodable, Sendable {
    let action: String
    let transfers: [TransferRecord]
    let copied: String?
    let message: String
    let state: ActionsState
}

/// One agent in a private data directory. With `platform`, the panel and its actions run
/// (clipboard capture included); without, it is a plain peer. The preferences domain the
/// agent writes to (shortcut bindings, a menu bar item's position) is saved before it starts
/// and put back after it stops. Every method blocks: call them through `actionsOffPool`.
private final class ActionsAgent: @unchecked Sendable {
    let directory: URL
    let executable: URL
    let platform: Bool
    let domain: String
    private var process: Process?
    private var savedPreferences: Data?
    private var preferencesSaved = false

    init(platform: Bool, executable: URL? = nil, domain: String = "catflap") throws {
        self.executable = try executable ?? locateExecutable()
        self.platform = platform
        self.domain = domain
        directory = try scratchDirectory(platform ? "ca-" : "cb-")
    }

    var socket: URL { directory.appendingPathComponent("control.sock") }
    var inbox: URL { directory.appendingPathComponent("inbox") }

    func command(_ arguments: [String], input: Data? = nil) throws -> ActionsCommand {
        try actionsRun(executable.path, arguments + ["--data-dir", directory.path, "--json"], input: input, in: directory)
    }

    func request(_ command: String, _ arguments: [String: String] = [:]) throws -> ControlResponse {
        try ControlClient.request(ControlRequest(command, arguments: arguments), socket: socket)
    }

    func invoke(_ action: String, _ arguments: [String: String] = [:]) throws -> ControlResponse {
        var all = arguments
        all["action"] = action
        return try request("ui.invoke", all)
    }

    func reply(_ action: String, _ arguments: [String: String] = [:]) throws -> ActionsReply {
        let response = try invoke(action, arguments)
        guard response.ok else { throw ActionsTestError.decode("\(action): refused: \(response.error ?? "no reason")") }
        do { return try response.decode(ActionsReply.self) } catch { throw ActionsTestError.decode("\(action): \(error)") }
    }

    func state() throws -> ActionsState {
        let response = try request("ui.state")
        guard response.ok else { throw ActionsTestError.decode("ui state refused") }
        return try response.decode(ActionsState.self)
    }

    func history() throws -> [TransferRecord] { try request("history").decode([TransferRecord].self) }
    func devices() throws -> [DeviceSummary] { try request("devices").decode([DeviceSummary].self) }

    /// Polls `probe` until it gives a value; the deadline only guards against a hang.
    func waitFor<T>(_ what: String, seconds: TimeInterval = 30, _ probe: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = try? probe() { return value }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let value = try probe() { return value }
        throw ActionsTestError.timeout(what)
    }

    func start(environment extra: [String: String] = [:], arguments prefix: [String] = []) throws {
        if !preferencesSaved {
            let export = try actionsRun("/usr/bin/defaults", ["export", domain, "-"], in: directory)
            savedPreferences = export.code == 0 ? export.output : nil
            preferencesSaved = true
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = prefix + ["agent", "--data-dir", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CATFLAP_PLATFORM"] = platform ? "on" : "off"
        environment.removeValue(forKey: "CATFLAP_STATUS_ITEM")
        for (key, value) in extra { environment[key] = value }
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, child.isRunning {
            if let status = try? request("status"), status.ok {
                if !platform { return }
                if let state = try? state(), state.ui.eventLoop, state.ui.shortcut != "unavailable" { return }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ActionsTestError.startup(child.isRunning ? "no answer within 30 s" : "exited \(child.terminationStatus)")
    }

    /// Stops the agent; returns the problems found on the way.
    func stop() -> [String] {
        guard let child = process else { return [] }
        process = nil
        if child.isRunning { child.terminate() }
        guard actionsWait(child, seconds: 7) != nil else {
            FileHandle.standardError.write(Data("harness-error: actions agent failed to stop within 7 s\n".utf8))
            kill(child.processIdentifier, SIGKILL); _ = actionsWait(child, seconds: 5)
            return ["Actions agent failed to stop within 7 s"]
        }
        return []
    }

    /// Stops the agent, puts the preferences back and removes what it left.
    func close() -> [String] {
        var problems = stop()
        if preferencesSaved {
            if let saved = savedPreferences {
                let file = directory.appendingPathComponent("preferences.plist")
                if (try? saved.write(to: file)) != nil {
                    _ = try? actionsRun("/usr/bin/defaults", ["import", domain, file.path], in: directory)
                }
            } else {
                _ = try? actionsRun("/usr/bin/defaults", ["delete", domain], in: directory)
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            if let result = try? actionsRun(executable.path, ["erase-identity", "--data-dir", directory.path], in: directory) {
                if result.code != 0 { problems.append("erase-identity exited \(result.code)") }
            } else { problems.append("Could not erase the test identity") }
            try? FileManager.default.removeItem(at: directory)
        }
        return problems
    }
}

/// The general pasteboard as it was, put back after the test. On CI it is the runner's.
@MainActor
private struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    init() throws {
        let board = NSPasteboard.general
        let count = board.changeCount
        items = try (board.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw ActionsTestError.snapshot }
                return (type, data)
            }
        }
        guard board.changeCount == count else { throw ActionsTestError.snapshot }
    }
    func restore() {
        let board = NSPasteboard.general
        board.clearContents()
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { _ = board.writeObjects(restored) }
    }
}

@Suite(.serialized)
struct MacActionsE2E {
    /// A panel agent and a peer, each with its inbox inside its own data directory.
    private func withAgents(peer: Bool = true, _ body: (ActionsAgent, ActionsAgent?) async throws -> Void) async throws {
        let saved = try await MainActor.run { try PasteboardSnapshot() }
        let panel = try ActionsAgent(platform: true)
        let other = peer ? try ActionsAgent(platform: false) : nil
        var failure: (any Error)?
        do {
            for agent in [panel, other].compactMap({ $0 }) {
                let store = try Store(paths: AgentPaths(directory: agent.directory))
                try await store.setSetting("inbox", value: agent.inbox.path)
            }
            try await actionsOffPool { try panel.start(); try other?.start() }
            try await body(panel, other)
        } catch { failure = error }
        let problems = (try? await actionsOffPool { panel.close() + (other?.close() ?? []) }) ?? ["could not stop the agents"]
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        await MainActor.run { saved.restore() }
        if let failure { throw failure }
    }

    /// Pairs the panel agent with `peer` from the panel: Pair a Device, Show a Code, Copy Code,
    /// the code pasted on the peer, the six digits compared and confirmed on both.
    private func pairFromPanel(_ panel: ActionsAgent, _ peer: ActionsAgent) async throws {
        let opened = try await actionsOffPool { try panel.reply("pair") }
        #expect(opened.state.actions.pairingOpen, "Pair a Device opens its window")
        _ = try await actionsOffPool { try panel.reply("pair-start") }
        let waiting = try await actionsOffPool {
            try panel.waitFor("a pairing code", seconds: 60) { () -> ActionsState? in
                let state = try panel.state()
                return state.actions.pairing.state == "waiting" && state.actions.pairing.hasCode ? state : nil
            }
        }
        #expect(waiting.actions.pairing.role == "initiator")
        let copied = try await actionsOffPool { try panel.invoke("pair-copy-code") }
        #expect(copied.ok, "Copy Code: \(copied.error ?? "")")
        // The code goes from the clipboard to the peer and is never printed.
        let (code, concealed) = await MainActor.run { () -> (String?, Bool) in
            let item = NSPasteboard.general.pasteboardItems?.first
            return (item?.string(forType: .string), item?.types.contains(.init("org.nspasteboard.ConcealedType")) ?? false)
        }
        #expect(concealed, "the copied code is marked concealed, so clipboard managers leave it out")
        let joinCode = try #require(code)
        let joined = try await actionsOffPool { try peer.request("pair.join", ["code": joinCode]) }
        #expect(joined.ok, "pair join: \(joined.error ?? "")")
        let (panelDigits, peerDigits) = try await actionsOffPool { () -> (String, String) in
            let shown = try panel.waitFor("the digits on the panel", seconds: 60) { () -> String? in
                let pairing = try panel.state().actions.pairing
                return pairing.state == "confirm" ? pairing.digits : nil
            }
            let other = try peer.waitFor("the digits on the peer", seconds: 60) { () -> String? in
                let status = try peer.request("pair.status").decode(PairingStatus.self)
                return status.state == .confirm ? status.digits : nil
            }
            return (shown, other)
        }
        let same = panelDigits == peerDigits && panelDigits.count == 6
        #expect(same, "both devices show the same six digits")
        #expect(try await actionsOffPool { try panel.invoke("pair-confirm") }.ok)
        #expect(try await actionsOffPool { try peer.request("pair.confirm") }.ok)
        let ended = try await actionsOffPool { () -> (String, PairingStatus.State) in
            let mine = try panel.waitFor("the panel's pairing to end", seconds: 90) { () -> String? in
                let pairing = try panel.state().actions.pairing
                return ["paired", "failed"].contains(pairing.state) ? pairing.state : nil
            }
            let theirs = try peer.waitFor("the peer's pairing to end", seconds: 90) { () -> PairingStatus.State? in
                let status = try peer.request("pair.status").decode(PairingStatus.self)
                return status.isActive ? nil : status.state
            }
            return (mine, theirs)
        }
        #expect(ended.0 == "paired" && ended.1 == .paired, "both devices paired")
        let listed = try await actionsOffPool { (try panel.devices().count, try peer.devices().count) }
        #expect(listed.0 == 1 && listed.1 == 1, "each device lists the other")
        _ = try await actionsOffPool { try panel.invoke("pair-close") }
        print("MacActionsE2E pairing: digits shown on both and equal=\(same) paired=\(ended.0)")
    }

    /// Waits until `agent` has a history row matching `match` with status ok.
    private func row(on agent: ActionsAgent, _ what: String, _ match: @escaping @Sendable (TransferRecord) -> Bool) async throws -> TransferRecord {
        try await actionsOffPool {
            try agent.waitFor(what, seconds: 60) { () -> TransferRecord? in
                try agent.history().first { match($0) && $0.status == "ok" }
            }
        }
    }

    @Test func testSendTextClipAttachAndCopyFromThePanel() async throws {
        try await withAgents { panel, peer in
            let peer = try #require(peer)
            let start = try await actionsOffPool { try panel.state() }
            #expect(start.actions.wired, "the panel's own controls reach the actions")
            try await pairFromPanel(panel, peer)

            // send-text, with the text given.
            let given = "panel send-text " + UUID().uuidString
            let sent = try await actionsOffPool { try panel.reply("send-text", ["text": given]) }
            #expect(sent.transfers.count == 1 && sent.transfers.first?.direction == "sent")
            let arrived = try await row(on: peer, "send-text on the peer") { $0.direction == "received" && $0.text == given }
            let here = try await row(on: panel, "send-text on the panel") { $0.direction == "sent" && $0.text == given }
            #expect(arrived.kind == "text" && here.id == arrived.id)
            print("MacActionsE2E send-text: sent=\(here.status) received=\(arrived.status)")

            // send-text from the command line, with the text typed into the field first.
            let typed = "typed in the field " + UUID().uuidString
            _ = try await actionsOffPool { try panel.reply("type", ["text": typed]) }
            let cli = try await actionsOffPool { try panel.command(["ui", "invoke", "send-text"]) }
            #expect(cli.code == 0, "ui invoke send-text: \(cli.errorText)")
            _ = try await row(on: peer, "typed text on the peer") { $0.direction == "received" && $0.text == typed }

            // send-clip: the newest clipboard row.
            let clip = "clipboard row " + UUID().uuidString
            let added = try await actionsOffPool { try panel.command(["clip", "add", "--text", clip]) }
            #expect(added.code == 0, "clip add: \(added.errorText)")
            let clipSent = try await actionsOffPool { try panel.command(["ui", "invoke", "send-clip"]) }
            #expect(clipSent.code == 0, "ui invoke send-clip: \(clipSent.errorText)")
            let clipArrived = try await row(on: peer, "send-clip on the peer") { $0.direction == "received" && $0.text == clip }
            _ = try await row(on: panel, "send-clip on the panel") { $0.direction == "sent" && $0.id == clipArrived.id }
            print("MacActionsE2E send-clip: received=\(clipArrived.status)")

            // attach, then the send button.
            let file = panel.directory.appendingPathComponent("attached-\(UUID().uuidString.prefix(6)).txt")
            try Data(("attached file " + UUID().uuidString).utf8).write(to: file)
            let expected = try TransferInbox.hash(file)
            let attached = try await actionsOffPool { try panel.reply("attach", ["files": file.path]) }
            #expect(attached.state.ui.attachments == 1 && attached.state.ui.mode == "focused", "attach opens a focused panel with the file")
            #expect(attached.state.ui.sendLabel.contains(file.lastPathComponent))
            let pressed = try await actionsOffPool { try panel.command(["ui", "invoke", "send"]) }
            #expect(pressed.code == 0, "ui invoke send: \(pressed.errorText)")
            let fileArrived = try await row(on: peer, "the attached file on the peer") { $0.direction == "received" && $0.kind == "file" }
            #expect(fileArrived.sha256 == expected, "the file arrives byte for byte")
            if let path = fileArrived.path { #expect(try TransferInbox.hash(URL(fileURLWithPath: path)) == expected) }
            _ = try await row(on: panel, "the attached file on the panel") { $0.direction == "sent" && $0.id == fileArrived.id }
            let cleared = try await actionsOffPool { try panel.waitFor("the attachment row to clear") { try panel.state().ui.attachments == 0 ? true : nil } }
            #expect(cleared)
            print("MacActionsE2E attach: received=\(fileArrived.status) hash_equal=\(fileArrived.sha256 == expected)")

            // copy: text from the peer arrives quietly with Copy; Copy puts it on the clipboard.
            let incoming = "copy me " + UUID().uuidString
            let panelID = try #require(try await actionsOffPool { try peer.devices().first?.id })
            let peerName = try #require(try await actionsOffPool { try panel.devices().first?.name })
            let fromPeer = try await actionsOffPool { try peer.command(["send", "--to", panelID, "--text", incoming]) }
            #expect(fromPeer.code == 0, "send from the peer: \(fromPeer.errorText)")
            let received = try await row(on: panel, "the peer's text on the panel") { $0.direction == "received" && $0.text == incoming }
            let notified = try await actionsOffPool {
                try panel.waitFor("the arrival notification") { () -> Notifier.Record? in
                    try panel.state().actions.notifications.last { $0.title == "Text from \(peerName)" }
                }
            }
            #expect(notified.action == "copy" && notified.body == incoming, "a quiet notification with Copy")
            let copied = try await actionsOffPool { try panel.command(["ui", "invoke", "copy"]) }
            #expect(copied.code == 0, "ui invoke copy: \(copied.errorText)")
            let pasted = try await actionsOffPool { try actionsRun("/usr/bin/pbpaste", [], in: panel.directory) }
            #expect(pasted.text == incoming, "pbpaste returns the copied text")
            print("MacActionsE2E copy: pbpaste_matches=\(pasted.text == incoming)")

            // delete: the row leaves the panel's history.
            let rowID = received.deviceID + "/" + received.id
            _ = try await actionsOffPool { try panel.reply("delete", ["id": rowID]) }
            let gone = try await actionsOffPool { try panel.history().contains { $0.id == received.id && $0.deviceID == received.deviceID } }
            #expect(!gone, "delete removes the row")
        }
    }

    @Test func testDontKeepPauseSendLatestAndRemove() async throws {
        try await withAgents { panel, peer in
            let peer = try #require(peer)
            // Right after a start nothing has been copied, and the shortcut says so.
            let refused = try await actionsOffPool { try panel.invoke("send-latest") }
            #expect(!refused.ok)
            #expect(refused.error == "Nothing has been copied since Catflap started.")
            let problem = try await actionsOffPool { try panel.state().actions.notifications.last }
            #expect(problem?.title == "Clipboard not sent" && problem?.body == "Nothing has been copied since Catflap started.")
            print("MacActionsE2E send-latest after start: \(refused.error ?? "accepted")")

            try await pairFromPanel(panel, peer)

            // Don't keep: both sides record the row without its text.
            let on = try await actionsOffPool { try panel.reply("dont-keep", ["value": "on"]) }
            #expect(on.state.actions.dontKeep)
            let secret = "not kept " + UUID().uuidString
            let started = try await actionsOffPool { try panel.reply("send-text", ["text": secret]) }
            let id = try #require(started.transfers.first?.id)
            let kept = try await row(on: peer, "the don't-keep row on the peer") { $0.id == id }
            #expect(kept.text == nil && !kept.keep, "the receiver stores no content")
            let mine = try await row(on: panel, "the don't-keep row on the panel") { $0.id == id }
            #expect(mine.text == nil && !mine.keep, "the sender stores no content")
            _ = try await actionsOffPool { try panel.reply("dont-keep", ["value": "off"]) }

            // Pause and resume clipboard history.
            let paused = try await actionsOffPool { try panel.reply("pause", ["value": "on"]) }
            #expect(paused.state.actions.paused)
            let resumed = try await actionsOffPool { try panel.reply("pause", ["value": "off"]) }
            #expect(!resumed.state.actions.paused)

            // The send-clipboard shortcut sends a copy the history recorded.
            let latest = "latest copy " + UUID().uuidString
            let copied = try await actionsOffPool { try actionsRun("/usr/bin/pbcopy", [], input: Data(latest.utf8), in: panel.directory) }
            #expect(copied.code == 0)
            _ = try await actionsOffPool {
                try panel.waitFor("the copy in clipboard history") { () -> Bool? in
                    try panel.request("clip.list").decode([ClipboardItem].self).contains { $0.text == latest } ? true : nil
                }
            }
            let shortcut = try await actionsOffPool { try panel.reply("send-latest") }
            #expect(shortcut.transfers.count == 1)
            _ = try await row(on: peer, "the latest copy on the peer") { $0.direction == "received" && $0.text == latest }
            let state = try await actionsOffPool { try panel.state() }
            #expect(state.actions.sendShortcut == "bound" && state.actions.sendShortcutKeys == "\u{2303}\u{2325}\u{21E7}Space")

            // Remove the peer in settings: this device forgets it.
            let peerID = try #require(try await actionsOffPool { try panel.devices().first?.id })
            _ = try await actionsOffPool { try panel.reply("remove", ["device": peerID]) }
            let left = try await actionsOffPool { try panel.devices().count }
            #expect(left == 0, "the removed device is gone")
        }
    }

    @Test func testSettingsSurviveARestart() async throws {
        try await withAgents(peer: false) { panel, _ in
            let folder = panel.directory.appendingPathComponent("received")
            let opened = try await actionsOffPool { try panel.reply("settings") }
            #expect(opened.state.actions.settingsOpen)
            for (key, value) in [("hover_band", "off"), ("hover_full_screen", "on"), ("received_text_to_clipboard", "on"),
                                 ("inbox", folder.path), ("panel_shortcut", "ctrl+option+cmd+k"), ("send_shortcut", "ctrl+option+cmd+j")] {
                let response = try await actionsOffPool { try panel.invoke("set", ["key": key, "value": value]) }
                #expect(response.ok, "set \(key): \(response.error ?? "")")
            }
            let relative = try await actionsOffPool { try panel.invoke("set", ["key": "inbox", "value": "relative/path"]) }
            #expect(!relative.ok && relative.error == "Choose a folder by its full path.")
            // A bare `catflap agent` is no app bundle, so it has no login item.
            let login = try await actionsOffPool { try panel.invoke("set", ["key": "start_at_login", "value": "on"]) }
            #expect(!login.ok && login.error == "Start at login is available when Catflap runs from Catflap.app.")
            _ = try await actionsOffPool { try panel.reply("settings-close") }

            let before = try await actionsOffPool { try panel.state().actions.settings }
            try await actionsOffPool {
                let problems = panel.stop()
                guard problems.isEmpty else { throw ActionsTestError.startup(problems.joined(separator: "; ")) }
                try panel.start()
            }
            let after = try await actionsOffPool { try panel.state() }
            #expect(after.actions.settings == before, "settings survive a restart")
            #expect(!after.actions.settings.hoverBand && after.actions.settings.hoverFullScreen && after.actions.settings.receivedTextToClipboard)
            #expect(after.actions.settings.inbox == folder.path)
            #expect(after.actions.panelShortcutKeys == "\u{2303}\u{2325}\u{2318}K" && after.actions.sendShortcutKeys == "\u{2303}\u{2325}\u{2318}J")
            #expect(after.actions.settings.startAtLogin == "unavailable")
            // With the hover band off, the panel still opens from the shortcut.
            let toggled = try await actionsOffPool { try panel.command(["toggle"]) }
            #expect(toggled.code == 0)
            print("MacActionsE2E settings after restart: hover_band=\(after.actions.settings.hoverBand) shortcut=\(after.actions.panelShortcutKeys)")
        }
    }

    @Test func testAttachPickerPastedDroppedAndServiceFiles() async throws {
        try await withAgents(peer: false) { panel, _ in
            let files = try (0..<3).map { index -> URL in
                let url = panel.directory.appendingPathComponent("file-\(index).txt")
                try Data("file \(index)".utf8).write(to: url)
                return url
            }
            // Attach without files opens the system's open panel.
            _ = try await actionsOffPool { try panel.reply("attach") }
            let open = try await actionsOffPool { try panel.waitFor("the open panel") { try panel.state().actions.pickerOpen ? true : nil } }
            #expect(open)
            _ = try await actionsOffPool { try panel.reply("attach-cancel") }
            let closed = try await actionsOffPool { try panel.waitFor("the open panel to close") { try panel.state().actions.pickerOpen ? nil : true } }
            #expect(closed)

            // Files on the clipboard are attached by a paste.
            await MainActor.run {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.writeObjects([files[0] as NSURL])
            }
            let pasted = try await actionsOffPool { try panel.reply("paste") }
            #expect(pasted.state.ui.mode == "focused" && pasted.state.ui.attachments == 1, "a pasted file is attached")

            // A file dropped on a dragged-open panel joins it, and the panel stays focused.
            _ = try await actionsOffPool { try panel.invoke("hide") }
            _ = try await actionsOffPool { try panel.invoke("simulate-drag") }
            let dropped = try await actionsOffPool { try panel.reply("simulate-drop", ["files": files[1].absoluteString]) }
            #expect(dropped.state.ui.mode == "focused" && dropped.state.ui.attachments == 2, "a dropped file is attached")

            // Finder's Services menu: the panel opens with the files attached.
            _ = try await actionsOffPool { try panel.invoke("hide") }
            let service = try await actionsOffPool { try panel.reply("service", ["files": files[2].path]) }
            #expect(service.state.ui.mode == "focused" && service.state.ui.attachments == 3)
            let missing = try await actionsOffPool { try panel.invoke("attach", ["files": panel.directory.appendingPathComponent("none").path]) }
            #expect(!missing.ok)
            print("MacActionsE2E attach: picker=\(open) paste=\(pasted.state.ui.attachments) drop=\(dropped.state.ui.attachments) service=\(service.state.ui.attachments)")
        }
    }

    @Test func testBundledAppIsSignedAndRunsWithoutTheCheckout() async throws {
        let executable = try locateExecutable()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let output = try scratchDirectory("cx-")
        defer { try? FileManager.default.removeItem(at: output) }
        let app = output.appendingPathComponent("Catflap.app")
        let built = try await actionsOffPool { () throws -> [ActionsCommand] in
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "CATFLAP_SIGN_IDENTITY")
            let bundle = try actionsRun("/bin/bash", [root.appendingPathComponent("packaging/macos/bundle.sh").path, "--binary", executable.path,
                                                      "--output", output.path], environment: environment, in: output, seconds: 120)
            let verify = try actionsRun("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path], in: output)
            let rpaths = try actionsRun("/usr/bin/otool", ["-l", app.appendingPathComponent("Contents/MacOS/catflap").path], in: output)
            let libraries = try actionsRun("/usr/bin/otool", ["-L", app.appendingPathComponent("Contents/MacOS/catflap").path], in: output)
            return [bundle, verify, rpaths, libraries]
        }
        #expect(built[0].code == 0, "bundle.sh: \(built[0].errorText)")
        #expect(built[1].code == 0, "codesign --verify: \(built[1].errorText)")
        let rpaths = built[2].text.components(separatedBy: "\n").enumerated().compactMap { index, line -> String? in
            guard line.contains("cmd LC_RPATH") else { return nil }
            let lines = built[2].text.components(separatedBy: "\n")
            guard index + 2 < lines.count else { return nil }
            let path = lines[index + 2].trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("path ") ? String(path.dropFirst(5).prefix { $0 != " " }) : nil
        }
        #expect(rpaths.contains("@executable_path/../Frameworks"), "the app looks for libtailcat inside itself")
        let reachingOut = rpaths.filter { !$0.hasPrefix("@") && !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("/System/") }
        #expect(reachingOut.isEmpty, "no search path outside the bundle and the system: \(reachingOut)")
        let dependencies = built[3].text.components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { String($0.prefix { $0 != " " }) }
        let outside = dependencies.filter { !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("/System/") && $0 != "@rpath/libtailcat.dylib" }
        #expect(outside.isEmpty, "only system libraries and the bundled libtailcat: \(outside)")
        let agentPlist = app.appendingPathComponent("Contents/Library/LaunchAgents/io.github.yigityazicilar.Catflap.agent.plist")
        let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: agentPlist), format: nil) as? [String: Any]
        #expect(agent?["BundleProgram"] as? String == "Contents/MacOS/catflap")
        #expect(agent?["ProgramArguments"] as? [String] == ["catflap", "agent"])
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        let services = info?["NSServices"] as? [[String: Any]]
        #expect(services?.first?["NSMessage"] as? String == "sendWithCatflap")

        // The app moved away from the build, with the checkout out of reach: `catflap version`
        // must load libtailcat from the bundle. The sandbox denies every read under the checkout.
        let moved = try scratchDirectory("cy-")
        defer { try? FileManager.default.removeItem(at: moved) }
        let installed = moved.appendingPathComponent("Catflap.app")
        let profile = "(version 1)(allow default)(deny file-read* (subpath \"\(root.path)\"))"
        let ran = try await actionsOffPool { () throws -> [ActionsCommand] in
            let copy = try actionsRun("/usr/bin/ditto", [app.path, installed.path], in: moved)
            let binary = installed.appendingPathComponent("Contents/MacOS/catflap").path
            let denied = try actionsRun("/usr/bin/sandbox-exec", ["-p", profile, "/bin/cat", root.appendingPathComponent("Package.swift").path], in: moved)
            let version = try actionsRun("/usr/bin/sandbox-exec", ["-p", profile, binary, "version"], in: moved)
            let verify = try actionsRun("/usr/bin/codesign", ["--verify", "--strict", "--deep", installed.path], in: moved)
            return [copy, denied, version, verify]
        }
        #expect(ran[0].code == 0, "ditto: \(ran[0].errorText)")
        #expect(ran[1].code != 0, "the sandbox keeps the checkout out of reach")
        #expect(ran[2].code == 0, "catflap version without the checkout: \(ran[2].errorText)")
        #expect(ran[2].text.components(separatedBy: "\n").contains("tailcat-abi 1"))
        #expect(ran[3].code == 0, "the moved app still verifies")
        print("MacActionsE2E bundle: rpaths=\(rpaths) outside_dependencies=\(outside.count) version_without_checkout_exit=\(ran[2].code) checkout_read_exit=\(ran[1].code)")

        // The agent as the app runs it: a bundle, so notifications go to Notification Center and
        // the login item can be switched. The app's preferences domain is saved and put back.
        let bundled = try ActionsAgent(platform: true, executable: installed.appendingPathComponent("Contents/MacOS/catflap"),
                                       domain: "io.github.yigityazicilar.Catflap")
        var failure: (any Error)?
        do {
            try await actionsOffPool { try bundled.start() }
            let state = try await actionsOffPool { try bundled.state() }
            #expect(state.actions.wired)
            #expect(state.actions.notificationDelivery == "notification_center")
            #expect(state.ui.statusItem, "the app shows its menu bar item")
            #expect(["off", "on", "requires_approval"].contains(state.actions.settings.startAtLogin), "login item: \(state.actions.settings.startAtLogin)")
            let on = try await actionsOffPool { try bundled.invoke("set", ["key": "start_at_login", "value": "on"]) }
            let afterOn = try await actionsOffPool { try bundled.state().actions.settings.startAtLogin }
            if on.ok { #expect(["on", "requires_approval"].contains(afterOn)) }
            else { #expect(on.error?.hasPrefix("macOS did not change the login item") == true, "\(on.error ?? "")") }
            let off = try await actionsOffPool { try bundled.invoke("set", ["key": "start_at_login", "value": "off"]) }
            let afterOff = try await actionsOffPool { try bundled.state().actions.settings.startAtLogin }
            #expect(off.ok && afterOff == "off", "the login item is off again: \(off.error ?? afterOff)")
            print("MacActionsE2E login item: on_accepted=\(on.ok) state_on=\(afterOn) state_off=\(afterOff) refusal=\(on.error ?? "none")")
        } catch { failure = error }
        let problems = (try? await actionsOffPool { bundled.close() }) ?? ["could not stop the bundled agent"]
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }
}
#endif
