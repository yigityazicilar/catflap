#if os(macOS)
@testable import CatflapMac
import AppKit
import CatflapCore
import CryptoKit
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

    /// Saves the preferences domain the agent writes to, once, so `close` can put it back.
    /// `start` does it too; a test that changes the domain before the agent starts calls it first.
    func savePreferences() throws {
        guard !preferencesSaved else { return }
        let export = try actionsRun("/usr/bin/defaults", ["export", domain, "-"], in: directory)
        savedPreferences = export.code == 0 ? export.output : nil
        preferencesSaved = true
    }

    /// Writes `value` as text under `key` in the agent's preferences domain, or deletes the key
    /// when it is nil. The domain is saved first, so `close` puts it back.
    func writePreference(_ key: String, _ value: String?) throws {
        try savePreferences()
        let arguments = value.map { ["write", domain, key, "-string", $0] } ?? ["delete", domain, key]
        let result = try actionsRun("/usr/bin/defaults", arguments, in: directory)
        // Deleting a key that is not there is no failure.
        guard result.code == 0 || value == nil else { throw ActionsTestError.startup("defaults \(arguments[0]) exited \(result.code)") }
    }

    /// How the agent's last run ended: its exit status, or 128 plus the signal that ended it.
    private(set) var exitStatus: Int32?

    func clipTexts() throws -> [String] { try request("clip.list").decode([ClipboardItem].self).compactMap(\.text) }

    /// The files in the agent's data folder (its database and write-ahead log included) that
    /// hold `text`, by name.
    func filesContaining(_ text: String) -> [String] {
        let needle = Data(text.utf8)
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return ["(the data folder could not be read)"]
        }
        var found: [String] = []
        while let url = walk.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), data.range(of: needle) != nil else { continue }
            found.append(url.lastPathComponent)
        }
        return found
    }

    /// `errors`, when given, keeps the agent's standard error there; a failed start quotes its end.
    /// `launcher`, when given, starts the agent through another program (sandbox-exec), with
    /// the agent's executable as its first argument; other commands still run it directly.
    func start(environment extra: [String: String] = [:], arguments prefix: [String] = [], errors: URL? = nil,
               launcher: (URL, [String])? = nil) throws {
        try savePreferences()
        let child = Process()
        child.executableURL = executable
        child.arguments = prefix + ["agent", "--data-dir", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CATFLAP_PLATFORM"] = platform ? "on" : "off"
        environment.removeValue(forKey: "CATFLAP_STATUS_ITEM")
        for (key, value) in extra { environment[key] = value }
        child.environment = environment
        if let launcher {
            child.executableURL = launcher.0
            child.arguments = launcher.1 + [executable.path] + (child.arguments ?? [])
        }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        if let errors {
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            child.standardError = try FileHandle(forWritingTo: errors)
        }
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
        let said = errors.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { " saying: " + String($0.suffix(400)) } ?? ""
        throw ActionsTestError.startup((child.isRunning ? "no answer within 30 s" : "exited \(child.terminationStatus)") + said)
    }

    /// Stops the agent; returns the problems found on the way.
    func stop() -> [String] {
        guard let child = process else { return [] }
        process = nil
        if child.isRunning { child.terminate() }
        // The wait only catches a hang: a slow runner must not fail this.
        guard let status = actionsWait(child, seconds: 30) else {
            FileHandle.standardError.write(Data("harness-error: actions agent failed to stop within 30 s\n".utf8))
            kill(child.processIdentifier, SIGKILL); _ = actionsWait(child, seconds: 5)
            return ["Actions agent failed to stop within 30 s"]
        }
        exitStatus = status
        return []
    }

    /// Stops the agent, puts the preferences back and removes what it left.
    func close() -> [String] {
        var problems = stop()
        if preferencesSaved {
            // The domain exactly as it was: what the run wrote goes, then what was there comes
            // back. An import over it alone would keep the keys the run added.
            _ = try? actionsRun("/usr/bin/defaults", ["delete", domain], in: directory)
            if let saved = savedPreferences,
               let values = try? PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any], !values.isEmpty {
                let file = directory.appendingPathComponent("preferences.plist")
                if (try? saved.write(to: file)) != nil {
                    _ = try? actionsRun("/usr/bin/defaults", ["import", domain, file.path], in: directory)
                }
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

/// One field of `ui state`, or of the `state` in an action's reply, as text; nil when the agent
/// does not report it. Read without the typed state, so these checks run against an agent
/// that lacks the field, and fail there.
private func stateField(_ payload: Data, _ name: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    let state = (object["state"] as? [String: Any]) ?? object
    return state[name].map { "\($0)" }
}

/// One of the settings in `ui state` (the object the settings window shows), as text.
private func settingsField(_ payload: Data, _ name: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    let state = (object["state"] as? [String: Any]) ?? object
    return (state["settings"] as? [String: Any])?[name].map { "\($0)" }
}

/// The lists `ui state`, or the `state` in an action's reply, says the panel could not read at
/// its latest refresh; nil when the agent does not report them.
private func unreadableLists(_ payload: Data) -> [String]? {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    let state = (object["state"] as? [String: Any]) ?? object
    return state["unreadable"] as? [String]
}

/// The attached files an action's reply says did not start, each with its reason.
private func notSentFiles(_ payload: Data) -> [(file: String, reason: String)] {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let list = object["not_sent"] as? [[String: Any]] else { return [] }
    return list.map { (file: $0["file"] as? String ?? "", reason: $0["reason"] as? String ?? "") }
}

/// Catflap.app as bundle.sh builds it from this build, copied away from the build, and the
/// sandbox profile that keeps the checkout out of reach of whatever runs under it.
private struct InstalledApp: Sendable {
    let folders: [URL]
    let app: URL
    let profile: String
    var binary: URL { app.appendingPathComponent("Contents/MacOS/catflap") }
    var launcher: (URL, [String]) { (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile]) }
    var folder: URL { folders[folders.count - 1] }

    static func make() throws -> InstalledApp {
        let executable = try locateExecutable()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let output = try scratchDirectory("cq-"), moved = try scratchDirectory("cr-")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CATFLAP_SIGN_IDENTITY")
        let bundle = try actionsRun("/bin/bash", [root.appendingPathComponent("packaging/macos/bundle.sh").path, "--binary", executable.path,
                                                  "--output", output.path], environment: environment, in: output, seconds: 120)
        guard bundle.code == 0 else { throw ActionsTestError.startup("bundle.sh exited \(bundle.code): \(bundle.errorText.suffix(300))") }
        let app = moved.appendingPathComponent("Catflap.app")
        let copy = try actionsRun("/usr/bin/ditto", [output.appendingPathComponent("Catflap.app").path, app.path], in: moved)
        guard copy.code == 0 else { throw ActionsTestError.startup("ditto exited \(copy.code)") }
        return InstalledApp(folders: [output, moved], app: app, profile: "(version 1)(allow default)(deny file-read* (subpath \"\(root.path)\"))")
    }

    func remove() { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
}

/// What a login-item agent leaves on this Mac: its launchd job, the default data folder and the
/// Keychain item of that folder's identity. Every method blocks.
private struct DefaultAgentTraces: Sendable {
    static let label = "io.github.yigityazicilar.Catflap.agent"
    let target = "gui/\(getuid())/\(Self.label)"
    let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catflap").standardizedFileURL
    /// The Keychain account of the default folder's identity, as the agent names it.
    var account: String { SHA256.hash(data: Data(data.path.utf8)).map { String(format: "%02x", $0) }.joined() }
    let scratch: URL

    /// Whether launchd has the job, and the process it runs, if one runs.
    func job() -> (loaded: Bool, pid: pid_t?) {
        guard let printed = try? actionsRun("/bin/launchctl", ["print", target], in: scratch), printed.code == 0 else { return (false, nil) }
        let line = printed.text.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
        return (true, line.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces).dropFirst(6)) })
    }

    var dataExists: Bool { FileManager.default.fileExists(atPath: data.path) }

    func keychainItem() -> Bool {
        (try? actionsRun("/usr/bin/security", ["find-generic-password", "-s", "Catflap.identity.v1", "-a", account], in: scratch))?.code == 0
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

extension ActionsAgent {
    func field(_ name: String) throws -> String? {
        let response = try request("ui.state")
        guard response.ok else { throw ActionsTestError.decode("ui state refused") }
        return stateField(response.payload, name)
    }

    /// Clicks one of the panel's own controls; `row` names the list row of a row control.
    func press(_ control: String, row: String? = nil) throws -> ControlResponse {
        var arguments = ["control": control]
        if let row { arguments["id"] = row }
        return try invoke("press", arguments)
    }

    /// A key equivalent pressed in the panel, such as `cmd` + `c`.
    func key(_ key: String, modifiers: String = "cmd") throws -> ControlResponse {
        try invoke("simulate-key", ["key": key, "modifiers": modifiers])
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

// The panel's own end-to-end suite and this one both drive focused panels, and there is one
// keyboard focus per machine: when one agent's panel stops being key, another's becomes key. So
// this suite runs inside MacPanelE2E, whose `.serialized` covers nested suites, and never
// beside it.
extension MacPanelE2E {
@Suite(.serialized)
struct MacActionsE2E {
    /// A panel agent and a peer, each with its inbox inside its own data directory. With
    /// `hooks`, the panel agent answers the test hooks (CATFLAP_TEST_HOOKS=on).
    private func withAgents(peer: Bool = true, hooks: Bool = false, _ body: (ActionsAgent, ActionsAgent?) async throws -> Void) async throws {
        let panel = try ActionsAgent(platform: true)
        let other = peer ? try ActionsAgent(platform: false) : nil
        var failure: (any Error)?
        do {
            for agent in [panel, other].compactMap({ $0 }) {
                let store = try Store(paths: AgentPaths(directory: agent.directory))
                try await store.setSetting("inbox", value: agent.inbox.path)
            }
            try await actionsOffPool { try panel.start(environment: hooks ? ["CATFLAP_TEST_HOOKS": "on"] : [:]); try other?.start() }
            try await body(panel, other)
        } catch { failure = error }
        let problems = (try? await actionsOffPool { panel.close() + (other?.close() ?? []) }) ?? ["could not stop the agents"]
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
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
        // Copy Code writes to a private pasteboard here, so a copy made by another test running
        // at the same time cannot get in between. The code goes to the peer and is never printed.
        let board = "io.github.yigityazicilar.Catflap.test." + UUID().uuidString
        let copied = try await actionsOffPool { try panel.invoke("pair-copy-code", ["pasteboard": board]) }
        #expect(copied.ok, "Copy Code: \(copied.error ?? "")")
        let (code, concealed) = await MainActor.run { () -> (String?, Bool) in
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(board))
            defer { pasteboard.releaseGlobally() }
            let item = pasteboard.pasteboardItems?.first
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
        // The panel's own lists, not only the agent, have the peer: the panel was closed while
        // pairing, so only the reload when pairing completes puts it there before the panel
        // opens. Sends from the panel's controls need it as their target.
        let known = try await actionsOffPool {
            try panel.waitFor("the closed panel to list the peer") { try panel.field("devices") == "1" ? true : nil }
        }
        #expect(known, "the closed panel lists the device just paired")
        print("MacActionsE2E pairing: digits shown on both and equal=\(same) paired=\(ended.0) panel_lists_peer=\(known)")
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

            // send-clip: a clipboard row, selected in the panel. The panel agent records the
            // copies other tests make, so the row is selected rather than taken as the newest.
            let clip = "clipboard row " + UUID().uuidString
            let added = try await actionsOffPool { try panel.command(["clip", "add", "--text", clip]) }
            #expect(added.code == 0, "clip add: \(added.errorText)")
            let clipID = try #require(try ControlJSON.decoder.decode(ClipboardIngestResult.self, from: added.output).id)
            let selected = try await actionsOffPool { try panel.reply("select", ["id": clipID]) }
            #expect(selected.state.ui.list == "clipboard")
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
            #expect(attached.state.ui.sendLabel.hasPrefix("Send "), "the send button names what it sends")
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
            // Copy writes the general pasteboard, which every test running at the same time
            // shares; it is saved first and put back after pbpaste. A copy that another test
            // overwrote before pbpaste read it is made again; a wrong result with no other
            // writer fails at once.
            let saved = try await MainActor.run { try PasteboardSnapshot() }
            var pastedText = ""
            var copyFailure: (any Error)?
            do {
                for attempt in 1...3 {
                    let before = await MainActor.run { NSPasteboard.general.changeCount }
                    let copied = try await actionsOffPool { try panel.command(["ui", "invoke", "copy"]) }
                    #expect(copied.code == 0, "ui invoke copy: \(copied.errorText)")
                    pastedText = try await actionsOffPool { try actionsRun("/usr/bin/pbpaste", [], in: panel.directory) }.text
                    let writes = await MainActor.run { NSPasteboard.general.changeCount } - before
                    if pastedText == incoming || writes <= 1 { break }
                    print("MacActionsE2E copy: another writer changed the pasteboard (\(writes) writes), attempt \(attempt)")
                }
            } catch { copyFailure = error }
            await MainActor.run { saved.restore() }
            if let copyFailure { throw copyFailure }
            #expect(pastedText == incoming, "pbpaste returns the copied text")
            print("MacActionsE2E copy: pbpaste_matches=\(pastedText == incoming)")

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

            // The send-clipboard shortcut sends the newest copy clipboard history recorded. The
            // copy is added through `clip add`, the path every capture takes into history, so
            // this test leaves the shared general pasteboard alone; the shortcut still reads it
            // once first, so a copy another test makes at that moment wins, and the step is made
            // again. Without another writer a wrong result fails at once.
            var latest = ""
            var shortcut: ActionsReply?
            for attempt in 1...3 {
                latest = "latest copy " + UUID().uuidString
                let text = latest
                let before = await MainActor.run { NSPasteboard.general.changeCount }
                let added = try await actionsOffPool { try panel.command(["clip", "add", "--text", text]) }
                #expect(added.code == 0, "clip add: \(added.errorText)")
                let reply = try await actionsOffPool { try panel.invoke("send-latest") }
                let writes = await MainActor.run { NSPasteboard.general.changeCount } - before
                let decoded = reply.ok ? (try? reply.decode(ActionsReply.self)) : nil
                let sentOther = decoded?.transfers.first?.text.map { $0 != text } ?? false
                if let decoded, !sentOther {
                    shortcut = decoded
                    break
                }
                if writes == 0 {
                    Issue.record(Comment(rawValue: "send-latest: \(reply.error ?? "sent another item")"))
                    break
                }
                print("MacActionsE2E send-latest: another writer changed the pasteboard (\(writes) writes), attempt \(attempt)")
            }
            #expect(shortcut?.transfers.count == 1)
            let sentLatest = latest
            _ = try await row(on: peer, "the latest copy on the peer") { $0.direction == "received" && $0.text == sentLatest }
            let state = try await actionsOffPool { try panel.state() }
            #expect(state.actions.sendShortcut == "bound" && state.actions.sendShortcutKeys == "\u{2303}\u{2325}\u{21E7}\u{2318}Space")

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

            // Files on the clipboard are attached by a paste (a private pasteboard here, as above).
            let board = "io.github.yigityazicilar.Catflap.test." + UUID().uuidString
            await MainActor.run {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name(board))
                pasteboard.clearContents()
                _ = pasteboard.writeObjects([files[0] as NSURL])
            }
            let pasted = try await actionsOffPool { try panel.reply("paste", ["pasteboard": board]) }
            await MainActor.run { NSPasteboard(name: NSPasteboard.Name(board)).releaseGlobally() }
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

    /// Catflap.app opened with no arguments (as Finder and `open` start it) runs the agent in
    /// its default data folder; the bare executable with no arguments still prints its help.
    /// The app runs with the checkout out of reach. The default folder is the person's own, so
    /// this runs on CI only, and only while that folder does not exist; the home folder stays
    /// the real one, because the agent's keys live in the login keychain under it.
    @Test func testOpeningTheAppWithoutArgumentsRunsTheAgent() async throws {
        let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catflap")
        guard ProcessInfo.processInfo.environment["CI"] == "true" else {
            print("MacActionsE2E app without arguments: skipped, it runs on CI only (it uses the default data folder)")
            return
        }
        // Declared before testBundledAppIsSignedAndRunsWithoutTheCheckout, whose login item, on
        // CI, starts a real agent in the default folder (and erases what it made).
        guard !FileManager.default.fileExists(atPath: data.path) else {
            Issue.record("Catflap's default data folder already exists on this runner; the test leaves it alone")
            return
        }
        let executable = try locateExecutable()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let output = try scratchDirectory("cz-")
        defer { try? FileManager.default.removeItem(at: output) }
        let app = output.appendingPathComponent("Catflap.app")
        let binary = app.appendingPathComponent("Contents/MacOS/catflap")
        let profile = "(version 1)(allow default)(deny file-read* (subpath \"\(root.path)\"))"
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CATFLAP_SIGN_IDENTITY")
        environment.removeValue(forKey: "CATFLAP_STATUS_ITEM")
        environment["CATFLAP_PLATFORM"] = "off"
        let fixed = environment
        let bundled = try await actionsOffPool {
            try actionsRun("/bin/bash", [root.appendingPathComponent("packaging/macos/bundle.sh").path, "--binary", executable.path,
                                         "--output", output.path], environment: fixed, in: output, seconds: 120)
        }
        #expect(bundled.code == 0, "bundle.sh: \(bundled.errorText)")

        let bare = try await actionsOffPool { try actionsRun(executable.path, [], environment: fixed, in: output) }
        let help = (bare.text + bare.errorText).contains("USAGE: catflap")
        #expect(help, "the bare executable prints its help")
        #expect(!FileManager.default.fileExists(atPath: data.path), "the bare executable started no agent")

        let (answered, exitCode, said) = try await actionsOffPool { () -> (Bool, Int32?, String) in
            let errors = output.appendingPathComponent("app-stderr.txt")
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            child.arguments = ["-p", profile, binary.path]
            child.environment = fixed
            child.standardOutput = FileHandle.nullDevice
            child.standardError = try FileHandle(forWritingTo: errors)
            child.standardInput = FileHandle.nullDevice
            try child.run()
            var answered = false
            // A hang guard only.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, child.isRunning {
                let status = try? ControlClient.request(ControlRequest("status"), socket: data.appendingPathComponent("control.sock"))
                if status?.ok == true { answered = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if child.isRunning { child.terminate() }
            var code = actionsWait(child, seconds: 30)
            if code == nil { kill(child.processIdentifier, SIGKILL); code = actionsWait(child, seconds: 5) }
            if FileManager.default.fileExists(atPath: data.path) {
                _ = try? actionsRun(binary.path, ["erase-identity", "--data-dir", data.path], environment: fixed, in: output)
                try? FileManager.default.removeItem(at: data)
            }
            return (answered, code, String((try? String(contentsOf: errors, encoding: .utf8))?.suffix(300) ?? ""))
        }
        #expect(answered, "the app with no arguments runs the agent in its default data folder: \(said)")
        #expect(exitCode == 0, "the agent stops cleanly on SIGTERM: \(exitCode.map { "\($0)" } ?? "no exit")")
        print("MacActionsE2E app without arguments: agent_answered=\(answered) exit=\(exitCode.map { "\($0)" } ?? "none") bare_prints_help=\(help)")
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
        let embedded = (try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let outside = dependencies.filter { dependency in
            if dependency.hasPrefix("/usr/lib/") || dependency.hasPrefix("/System/") { return false }
            if dependency.hasPrefix("@rpath/") { return !embedded.contains(String(dependency.dropFirst(7))) }
            return true
        }
        #expect(outside.isEmpty, "only system libraries and libraries inside the bundle: \(outside)")
        #expect(embedded.contains("libtailcat.dylib"))
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

        // The agent as the app runs it, with the checkout still out of reach: nothing it loads
        // may come from the build. A bundle, so notifications go to Notification Center and the
        // login item can be switched. The app's preferences domain is saved and put back.
        let bundled = try ActionsAgent(platform: true, executable: installed.appendingPathComponent("Contents/MacOS/catflap"),
                                       domain: "io.github.yigityazicilar.Catflap")
        let agentErrors = moved.appendingPathComponent("agent-stderr.txt")
        var failure: (any Error)?
        do {
            try await actionsOffPool {
                try bundled.start(errors: agentErrors, launcher: (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile]))
            }
            let state = try await actionsOffPool { try bundled.state() }
            #expect(state.actions.wired)
            #expect(state.actions.notificationDelivery == "notification_center")
            #expect(state.ui.statusItem, "the app shows its menu bar item")
            #expect(["off", "on", "requires_approval"].contains(state.actions.settings.startAtLogin), "login item: \(state.actions.settings.startAtLogin)")
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                try await switchLoginItemOnAndOff(bundled, binary: installed.appendingPathComponent("Contents/MacOS/catflap"))
            } else {
                print("MacActionsE2E login item: not switched; that runs on CI only, where no login item, data or Keychain item of a person's can change")
            }
        } catch { failure = error }
        let problems = (try? await actionsOffPool { bundled.close() }) ?? ["could not stop the bundled agent"]
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }

    /// Start at login switched on and off in the installed app. Switching it on makes launchd
    /// start a second agent, `catflap agent` in the default data folder, which makes an identity
    /// and its Keychain item there. So this runs on CI only, and only when the runner has none of
    /// these yet. Afterwards, after a failure as well, the job is stopped and only what it made is
    /// erased, and nothing may be left: no job, no process, no default folder, no Keychain item.
    private func switchLoginItemOnAndOff(_ bundled: ActionsAgent, binary: URL) async throws {
        let traces = DefaultAgentTraces(scratch: bundled.directory)
        let before = try await actionsOffPool { () -> (job: Bool, data: Bool, key: Bool, login: String) in
            let login = try bundled.state().actions.settings.startAtLogin
            return (traces.job().loaded, traces.dataExists, traces.keychainItem(), login)
        }
        guard !before.job, !before.data, !before.key, before.login == "off" else {
            Issue.record("Catflap's login item, default data folder or Keychain item is already on this runner (job=\(before.job) data=\(before.data) keychain=\(before.key) login=\(before.login)); the test leaves them alone")
            return
        }
        var pid: pid_t?
        var failure: (any Error)?
        do {
            let on = try await actionsOffPool { try bundled.invoke("set", ["key": "start_at_login", "value": "on"]) }
            let afterOn = try await actionsOffPool { try bundled.state().actions.settings.startAtLogin }
            if on.ok { #expect(["on", "requires_approval"].contains(afterOn)) }
            else { #expect(on.error?.hasPrefix("macOS did not change the login item") == true, "\(on.error ?? "")") }
            var answered = false
            if afterOn == "on" {
                // launchd starts the job at once (RunAtLoad). Its agent answers once it has made
                // its identity, so all it makes is there before it is stopped.
                (pid, answered) = try await actionsOffPool { () -> (pid_t?, Bool) in
                    var seen: pid_t?
                    let ok = (try? bundled.waitFor("the login item's agent", seconds: 60) { () -> Bool? in
                        if seen == nil { seen = traces.job().pid }
                        let status = try? ControlClient.request(ControlRequest("status"), socket: traces.data.appendingPathComponent("control.sock"))
                        return status?.ok == true ? true : nil
                    }) ?? false
                    return (seen ?? traces.job().pid, ok)
                }
            }
            let off = try await actionsOffPool { try bundled.invoke("set", ["key": "start_at_login", "value": "off"]) }
            let afterOff = try await actionsOffPool { try bundled.state().actions.settings.startAtLogin }
            #expect(off.ok && afterOff == "off", "the login item is off again: \(off.error ?? afterOff)")
            // What switching it off leaves by itself, before this test cleans up.
            let seen = pid
            let left = try await actionsOffPool { () -> String in
                "job=\(traces.job().loaded) process=\(seen.map(DefaultAgentTraces.alive) ?? false) data=\(traces.dataExists) keychain=\(traces.keychainItem())"
            }
            print("MacActionsE2E login item: on_accepted=\(on.ok) state_on=\(afterOn) state_off=\(afterOff) refusal=\(on.error ?? "none") agent_started=\(pid != nil) agent_answered=\(answered) left_after_switching_off: \(left)")
        } catch { failure = error }

        // The cleanup, after a failure too: the login item off, its job out of launchd, its
        // process ended, and the identity and folder it made erased.
        let started = pid
        let residue = try await actionsOffPool { () -> [String] in
            _ = try? bundled.invoke("set", ["key": "start_at_login", "value": "off"])
            if traces.job().loaded { _ = try? actionsRun("/bin/launchctl", ["bootout", traces.target], in: traces.scratch) }
            var problems: [String] = []
            if let started {
                // A hang guard only: launchd ends the job's process when the job goes.
                let deadline = Date().addingTimeInterval(30)
                while DefaultAgentTraces.alive(started), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if DefaultAgentTraces.alive(started) {
                    problems.append("the login item's agent did not end with its job")
                    kill(started, SIGKILL)
                }
            }
            if traces.dataExists {
                let erased = try? actionsRun(binary.path, ["erase-identity", "--data-dir", traces.data.path], in: traces.scratch)
                if erased?.code != 0 { problems.append("erase-identity of the default folder exited \(erased.map { "\($0.code)" } ?? "without starting")") }
                try? FileManager.default.removeItem(at: traces.data)
            }
            if traces.keychainItem() {
                _ = try? actionsRun("/usr/bin/security", ["delete-generic-password", "-s", "Catflap.identity.v1", "-a", traces.account], in: traces.scratch)
            }
            if traces.job().loaded { problems.append("the login item's launchd job is still there") }
            if let started, DefaultAgentTraces.alive(started) { problems.append("the login item's agent still runs") }
            if traces.dataExists { problems.append("the default data folder is still there") }
            if traces.keychainItem() { problems.append("the default folder's Keychain item is still there") }
            return problems
        }
        #expect(residue.isEmpty, "the login item left: \(residue)")
        print("MacActionsE2E login item cleanup: left=\(residue.isEmpty ? "nothing" : residue.joined(separator: "; "))")
        if let failure { throw failure }
    }

    /// Attach, Pair a device and Settings, clicked on the panel itself, open what they name.
    @Test func testPanelButtonsReachTheActions() async throws {
        try await withAgents(peer: false) { panel, _ in
            let start = try await actionsOffPool { try panel.state() }
            #expect(start.actions.wired, "the panel's own controls reach the actions")
            var opened: [String: Bool] = [:]
            // Pair a device is in the panel while no device is paired.
            for (control, close) in [("attach", "attach-cancel"), ("pair", "pair-close"), ("settings", "settings-close")] {
                _ = try await actionsOffPool { try panel.reply("type", ["text": ""]) }
                let pressed = try await actionsOffPool { try panel.press(control) }
                #expect(pressed.ok, "press \(control): \(pressed.error ?? "")")
                guard pressed.ok else { opened[control] = false; continue }
                opened[control] = try await actionsOffPool {
                    try panel.waitFor("the window behind \(control)") { () -> Bool? in
                        let actions = try panel.state().actions
                        let open = switch control {
                        case "attach": actions.pickerOpen
                        case "pair": actions.pairingOpen
                        default: actions.settingsOpen
                        }
                        return open ? true : nil
                    }
                }
                _ = try await actionsOffPool { try panel.reply(close) }
            }
            #expect(opened == ["attach": true, "pair": true, "settings": true], "\(opened)")
            print("MacActionsE2E buttons: " + opened.keys.sorted().map { "\($0)=\(opened[$0] ?? false)" }.joined(separator: " "))
        }
    }

    /// Copy and Delete on the list's rows: by their buttons, and by ⌘C and ⌘⌫ on the selected
    /// row, each button with a spoken label naming its row.
    @Test func testRowCopyAndDeleteControls() async throws {
        try await withAgents(peer: false) { panel, _ in
            let marker = UUID().uuidString
            let texts = ["copy by click " + marker, "copy by key " + marker]
            var ids: [String] = []
            for text in texts {
                let added = try await actionsOffPool { try panel.command(["clip", "add", "--text", text]) }
                #expect(added.code == 0, "clip add: \(added.errorText)")
                ids.append(try #require(try ControlJSON.decoder.decode(ClipboardIngestResult.self, from: added.output).id))
            }
            let rows = ids
            // The field filters the list down to this test's two rows.
            _ = try await actionsOffPool { try panel.reply("type", ["text": marker]) }
            let listed = try await actionsOffPool { try panel.waitFor("both rows in the panel") { try panel.state().ui.rows == 2 ? true : nil } }
            #expect(listed)

            // Copy writes the general pasteboard: it is saved first and put back after.
            let saved = try await MainActor.run { try PasteboardSnapshot() }
            var pasted: [String] = []
            var labels: [String] = []
            var failure: (any Error)?
            do {
                let click = try await actionsOffPool { try panel.press("copy", row: rows[0]) }
                #expect(click.ok, "press copy: \(click.error ?? "")")
                if click.ok { labels.append(try click.decode(ActionsReply.self).message) }
                pasted.append(await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" })
                _ = try await actionsOffPool { try panel.reply("select", ["id": rows[1]]) }
                let key = try await actionsOffPool { try panel.key("c") }
                #expect(key.ok, "cmd-C: \(key.error ?? "")")
                pasted.append(await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" })
            } catch { failure = error }
            await MainActor.run { saved.restore() }
            if let failure { throw failure }
            #expect(pasted == texts, "the Copy button copies its row, cmd-C the selected row")

            _ = try await actionsOffPool { try panel.reply("select", ["id": rows[1]]) }
            let deleteKey = try await actionsOffPool { try panel.key("delete") }
            #expect(deleteKey.ok, "cmd-delete: \(deleteKey.error ?? "")")
            let deleteClick = try await actionsOffPool { try panel.press("delete", row: rows[0]) }
            #expect(deleteClick.ok, "press delete: \(deleteClick.error ?? "")")
            if deleteClick.ok { labels.append(try deleteClick.decode(ActionsReply.self).message) }
            let left = try await actionsOffPool { try panel.command(["clip", "list"]) }.text
            let gone = ids.map { !left.contains($0) }
            #expect(gone == [true, true], "both rows are deleted")
            #expect(labels == ["Copy " + texts[0], "Delete " + texts[0]], "spoken labels: \(labels)")
            print("MacActionsE2E row controls: pasted_match=\(pasted == texts) deleted=\(gone) labels=\(labels.map { $0.replacingOccurrences(of: marker, with: "<marker>") })")
        }
    }

    /// The menu bar glyph and the panel's line follow each send: cf-moving while it goes,
    /// cf-arrived after it got there or something arrived, cf-problem after a failure until the
    /// panel opens. A failure notifies while the panel is closed; Retry is clicked on its row.
    @Test func testStatusGlyphAndTheLastSendLine() async throws {
        try await withAgents { panel, peer in
            let peer = try #require(peer)
            try await pairFromPanel(panel, peer)
            let peerName = try #require(try await actionsOffPool { try panel.devices().first?.name })
            let idle = try await actionsOffPool { try panel.field("glyph") }
            #expect(idle == "cf-idle")

            // The send button with a file attached, pressed once it names the peer.
            let file = panel.directory.appendingPathComponent("large-\(UUID().uuidString.prefix(6)).bin")
            try Data(count: 32 << 20).write(to: file)
            let attached = try await actionsOffPool { try panel.reply("attach", ["files": file.path]) }
            let named = try await actionsOffPool {
                try panel.waitFor("the send button to name the peer") { () -> Bool? in
                    try panel.field("send_label")?.hasSuffix(" to \(peerName)") == true ? true : nil
                }
            }
            #expect(named, "Send names the peer before it is pressed")
            print("MacActionsE2E glyph: send label named the peer at attach=\(attached.state.ui.sendLabel.hasSuffix(" to \(peerName)"))")
            let pressed = try await actionsOffPool { try panel.press("send") }
            #expect(pressed.ok, "press send: \(pressed.error ?? "")")
            #expect(stateField(pressed.payload, "glyph") == "cf-moving", "the glyph while the file goes")
            #expect(stateField(pressed.payload, "send_line")?.hasPrefix("Sending to \(peerName)") == true)
            _ = try await row(on: peer, "the file on the peer") { $0.direction == "received" && $0.kind == "file" }
            _ = try await row(on: panel, "the file sent from the panel") { $0.direction == "sent" && $0.kind == "file" }
            let (line, lasted) = try await actionsOffPool { () -> (String?, TimeInterval) in
                _ = try panel.waitFor("cf-arrived after the send") { try panel.field("glyph") == "cf-arrived" ? true : nil }
                let seen = Date()
                let line = try panel.field("send_line")
                _ = try panel.waitFor("cf-idle after cf-arrived") { try panel.field("glyph") == "cf-idle" ? true : nil }
                return (line, Date().timeIntervalSince(seen))
            }
            #expect(line == "Sent to \(peerName).")
            print("MacActionsE2E glyph: cf-arrived then cf-idle after \(String(format: "%.1f", lasted)) s")

            // Something arriving.
            let panelID = try #require(try await actionsOffPool { try peer.devices().first?.id })
            let fromPeer = try await actionsOffPool { try peer.command(["send", "--to", panelID, "--text", "arriving " + UUID().uuidString]) }
            #expect(fromPeer.code == 0, "send from the peer: \(fromPeer.errorText)")
            let arrival = try await actionsOffPool { try panel.waitFor("cf-arrived after an arrival") { try panel.field("glyph") == "cf-arrived" ? true : nil } }
            #expect(arrival)

            // A send that fails while the panel is closed.
            _ = try await actionsOffPool { try panel.invoke("hide") }
            let stopped = try await actionsOffPool { peer.stop() }
            #expect(stopped.isEmpty, "\(stopped)")
            let failing = try await actionsOffPool { try panel.invoke("send-text", ["text": "to a stopped peer " + UUID().uuidString]) }
            #expect(failing.ok, "send-text: \(failing.error ?? "")")
            #expect(stateField(failing.payload, "glyph") == "cf-moving")
            let failed = try #require(try failing.decode(ActionsReply.self).transfers.first)
            let failedRow = failed.deviceID + "/" + failed.id
            let started = Date()
            let afterFailure = try await actionsOffPool { () -> ActionsState in
                _ = try panel.waitFor("cf-problem", seconds: 90) { try panel.field("glyph") == "cf-problem" ? true : nil }
                return try panel.state()
            }
            let took = Date().timeIntervalSince(started)
            let failureLine = try await actionsOffPool { try panel.field("send_line") }
            #expect(failureLine?.hasPrefix("Not sent to \(peerName).") == true, "\(failureLine ?? "no line")")
            #expect(afterFailure.actions.notifications.last?.title == "Not sent to \(peerName)", "a closed panel still notifies")
            print("MacActionsE2E glyph: cf-problem \(String(format: "%.1f", took)) s after the send to the stopped peer")

            // Opening the panel takes cf-problem away.
            let opened = try await actionsOffPool { try panel.reply("type", ["text": ""]) }
            #expect(opened.state.ui.visible)
            #expect(try await actionsOffPool { try panel.field("glyph") } == "cf-idle", "the panel opened")

            // Retry on the failed row, with the panel open: the line says how it went, and there
            // is no notification beside it. The panel opened a moment ago, and its lists come
            // from its own refresh: Retry is pressed once the panel lists every history row.
            let notified = afterFailure.actions.notifications.count
            let historyCount = try await actionsOffPool { try panel.history().count }
            let listed = try await actionsOffPool {
                try panel.waitFor("the open panel to list the failed row") { try panel.field("history_rows") == "\(historyCount)" ? true : nil }
            }
            #expect(listed, "the open panel lists the failed row")
            _ = try await actionsOffPool { try panel.reply("select", ["id": failedRow]) }
            let retried = try await actionsOffPool { try panel.press("retry", row: failedRow) }
            #expect(retried.ok, "press retry: \(retried.error ?? "")")
            #expect(stateField(retried.payload, "glyph") == "cf-moving")
            if retried.ok {
                let again = try await actionsOffPool { () -> ActionsState in
                    _ = try panel.waitFor("cf-problem after Retry", seconds: 90) { try panel.field("glyph") == "cf-problem" ? true : nil }
                    return try panel.state()
                }
                #expect(again.ui.visible, "the panel stayed open")
                #expect(again.actions.notifications.count == notified, "no notification while the panel is open")
                #expect(try await actionsOffPool { try panel.field("send_line") }?.hasPrefix("Not sent to \(peerName).") == true)
            }
        }
    }

    // MARK: Shortcuts

    static let appDomain = "io.github.yigityazicilar.Catflap"
    static let panelKey = "KeyboardShortcuts_togglePanel"
    static let sendKey = "KeyboardShortcuts_sendClipboard"
    static let panelDefault = TestShortcut.controlOptionCommand(TestShortcut.space)
    static let sendDefault = TestShortcut.controlOptionCommand(TestShortcut.space, shift: true)

    /// Presses `open` and then `send` on the keyboard, through the window server, with the panel
    /// closed. `send` sends the clipboard, which fails here (nothing copied, or no device), and
    /// the menu bar glyph shows cf-problem. Keys arrive in order, so by then `open` has been
    /// handled, and the panel must be open and focused. On CI only: the runner lets the tests
    /// post key events, and a person's own session gets no keys from a test.
    private func pressShortcuts(_ agent: ActionsAgent, open: TestShortcut, send: TestShortcut, _ step: String) async throws {
        guard ProcessInfo.processInfo.environment["CI"] == "true" else {
            print("MacActionsE2E \(step): shortcut keys not pressed; that runs on CI only")
            return
        }
        guard SystemKeys.canPost else {
            Issue.record(Comment(rawValue: "\(step): this runner does not let the tests post key events"))
            return
        }
        // Opening the panel clears cf-problem; it closes again before the keys.
        let ready = try await actionsOffPool { () -> (String?, String?) in
            _ = try agent.invoke("hide")
            _ = try agent.invoke("toggle")
            _ = try agent.invoke("hide")
            return (try agent.field("mode"), try agent.field("glyph"))
        }
        #expect(ready.0 == "hidden" && ready.1 != "cf-problem", "\(step): a closed panel and no cf-problem before the keys")
        let pressed = SystemKeys.press(open) && SystemKeys.press(send)
        #expect(pressed, "\(step): the key events were made")
        let after = try await actionsOffPool {
            try agent.waitFor("\(step): what \(send) does", seconds: 30) { () -> Data? in
                let payload = try agent.request("ui.state").payload
                return stateField(payload, "glyph") == "cf-problem" ? payload : nil
            }
        }
        let mode = stateField(after, "mode") ?? "none"
        #expect(mode == "focused" && stateField(after, "has_focus") == "1", "\(step): \(open) opened the panel, focused, before \(send) was handled")
        print("MacActionsE2E \(step): \(open) then \(send): mode=\(mode) glyph=cf-problem")
        _ = try await actionsOffPool { try agent.invoke("hide") }
    }

    /// A shortcut refused inside the agent's own process is a conflict that the installed app
    /// reports and survives, with the checkout out of reach. Before the agent starts, both
    /// shortcuts are set to one combination, written as KeyboardShortcuts wrote it: the panel's
    /// registration takes it, and the second registration is refused (eventHotKeyExistsErr).
    /// The agent goes on answering the command line and changing settings. Rebound to a free
    /// combination, the refused shortcut works, and the panel's still does.
    @Test func testARefusedShortcutIsAConflictTheInstalledAgentSurvives() async throws {
        let installed = try await actionsOffPool { try InstalledApp.make() }
        defer { installed.remove() }
        let taken = TestShortcut.controlOptionCommand(TestShortcut.letterJ)
        let free = TestShortcut.controlOptionCommand(TestShortcut.letterL)
        let agent = try ActionsAgent(platform: true, executable: installed.binary, domain: Self.appDomain)
        let errors = installed.folder.appendingPathComponent("agent-stderr.txt")
        var failure: (any Error)?
        do {
            try await actionsOffPool {
                for key in [Self.panelKey, Self.sendKey] { try agent.writePreference(key, taken.preference) }
                try agent.start(errors: errors, launcher: installed.launcher)
            }
            let first = try await actionsOffPool { try agent.request("ui.state").payload }
            print("MacActionsE2E refused shortcut: panel=\(stateField(first, "shortcut") ?? "none") send=\(stateField(first, "send_shortcut") ?? "none")")
            #expect(stateField(first, "shortcut") == "bound" && stateField(first, "shortcut_keys") == taken.description, "the panel's registration holds \(taken)")
            #expect(stateField(first, "send_shortcut") == "conflict", "the refused registration is a conflict, not bound")
            #expect(stateField(first, "send_shortcut_keys") == taken.description)
            #expect(settingsField(first, "send_shortcut_state") == "conflict", "settings show the conflict")
            #expect(settingsField(first, "panel_shortcut_state") == "bound")

            // The agent goes on: it answers the command line, and a setting changes.
            let status = try await actionsOffPool {
                try actionsRun("/usr/bin/sandbox-exec", ["-p", installed.profile, installed.binary.path, "status", "--data-dir", agent.directory.path, "--json"],
                               in: agent.directory)
            }
            #expect(status.code == 0, "catflap status beside a refused shortcut: \(status.errorText)")
            let changed = try await actionsOffPool { try agent.reply("set", ["key": "hover_band", "value": "off"]) }
            #expect(!changed.state.actions.settings.hoverBand, "a settings change beside a refused shortcut")

            // Rebound to a free combination, the refused one is bound; the panel's keeps its own.
            let rebound = try await actionsOffPool { try agent.invoke("set", ["key": "send_shortcut", "value": "ctrl+option+cmd+l"]) }
            #expect(rebound.ok, "rebinding the refused shortcut: \(rebound.error ?? "")")
            let after = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(after, "send_shortcut") == "bound" && stateField(after, "send_shortcut_keys") == free.description)
            #expect(settingsField(after, "send_shortcut_state") == "bound")
            #expect(stateField(after, "shortcut") == "bound" && stateField(after, "shortcut_keys") == taken.description)
            try await pressShortcuts(agent, open: taken, send: free, "refused shortcut rebound")
            // A rebind onto what the other one holds is refused, and the panel's stays as it was.
            let clash = try await actionsOffPool { try agent.invoke("set", ["key": "panel_shortcut", "value": "ctrl+option+cmd+l"]) }
            #expect(!clash.ok, "a combination the other shortcut holds is refused")
            let kept = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(kept, "shortcut") == "bound" && stateField(kept, "shortcut_keys") == taken.description)
            try await pressShortcuts(agent, open: taken, send: free, "after a refused rebind")
        } catch { failure = error }
        let problems = try await actionsOffPool { agent.close() }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        let said = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        let fatal = said.contains("Fatal error") || said.contains("could not load resource bundle")
        print("MacActionsE2E refused shortcut: agent_exit=\(agent.exitStatus.map { "\($0)" } ?? "none") fatal_in_stderr=\(fatal)")
        #expect(!fatal, "the agent did not stop on a refused shortcut")
        #expect(agent.exitStatus == 0, "the agent stops cleanly on SIGTERM")
        if let failure { throw failure }
    }

    /// The default shortcuts, ⌃⌥⌘Space for the panel and ⌃⌥⇧⌘Space to send the clipboard, are
    /// free of macOS's own shortcuts on this Mac, register, and work. (The earlier ⌃⌥Space is
    /// macOS's Select next source in Input menu.)
    @Test func testDefaultShortcutsAreFreeOfMacOSAndWork() async throws {
        let system = SystemKeys.systemShortcuts()
        let candidates = [TestShortcut.controlOption(TestShortcut.space), Self.panelDefault, TestShortcut.controlOptionCommand(TestShortcut.letterK),
                          Self.sendDefault, TestShortcut.controlOptionCommand(TestShortcut.letterK, shift: true)]
        let listed = candidates.map { candidate -> String in "\(candidate)=" + (system.contains(candidate) ? "macOS" : "free") }
        print("MacActionsE2E macOS shortcuts: \(system.count) enabled; \(listed.joined(separator: " ")) post_events=\(SystemKeys.canPost)")
        #expect(!system.contains(Self.panelDefault) && !system.contains(Self.sendDefault), "macOS has no shortcut of its own on the defaults")
        let agent = try ActionsAgent(platform: true)
        var failure: (any Error)?
        do {
            try await actionsOffPool {
                for key in [Self.panelKey, Self.sendKey] { try agent.writePreference(key, nil) }
                try agent.start()
            }
            let state = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(state, "shortcut") == "bound" && stateField(state, "shortcut_keys") == Self.panelDefault.description,
                    "panel: \(stateField(state, "shortcut") ?? "none") \(stateField(state, "shortcut_keys") ?? "")")
            #expect(stateField(state, "send_shortcut") == "bound" && stateField(state, "send_shortcut_keys") == Self.sendDefault.description,
                    "send: \(stateField(state, "send_shortcut") ?? "none") \(stateField(state, "send_shortcut_keys") ?? "")")
            try await pressShortcuts(agent, open: Self.panelDefault, send: Self.sendDefault, "default shortcuts")
        } catch { failure = error }
        let problems = try await actionsOffPool { agent.close() }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }

    /// A combination macOS keeps for one of its own enabled shortcuts is never claimed bound:
    /// the panel's shortcut, set to one of this Mac's before the agent starts, is a conflict.
    /// The agent still answers, and rebound to a free combination the panel opens on it.
    @Test func testAShortcutMacOSKeepsIsAConflictUntilRebound() async throws {
        let system = SystemKeys.systemShortcuts()
        guard let taken = system.first(where: { $0.modifiers != 0 && $0 != Self.panelDefault && $0 != Self.sendDefault }) else {
            Issue.record(Comment(rawValue: "this Mac lists no enabled macOS shortcut with modifiers (\(system.count) enabled) to test against"))
            return
        }
        let agent = try ActionsAgent(platform: true)
        var failure: (any Error)?
        do {
            try await actionsOffPool {
                try agent.writePreference(Self.panelKey, taken.preference)
                try agent.writePreference(Self.sendKey, nil)
                try agent.start()
            }
            let first = try await actionsOffPool { try agent.request("ui.state").payload }
            print("MacActionsE2E macOS shortcut \(taken): panel=\(stateField(first, "shortcut") ?? "none")")
            #expect(stateField(first, "shortcut") == "conflict", "\(taken), which macOS keeps, is not claimed bound")
            #expect(settingsField(first, "panel_shortcut_state") == "conflict", "settings show the conflict")
            #expect(stateField(first, "send_shortcut") == "bound")
            let status = try await actionsOffPool { try agent.request("status") }
            #expect(status.ok, "the agent still answers")
            let rebound = try await actionsOffPool { try agent.invoke("set", ["key": "panel_shortcut", "value": "ctrl+option+cmd+space"]) }
            #expect(rebound.ok, "rebinding to a free combination: \(rebound.error ?? "")")
            let after = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(after, "shortcut") == "bound" && stateField(after, "shortcut_keys") == Self.panelDefault.description)
            try await pressShortcuts(agent, open: Self.panelDefault, send: Self.sendDefault, "rebound from a macOS shortcut")
        } catch { failure = error }
        let problems = try await actionsOffPool { agent.close() }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }

    /// Recording a shortcut in settings unregisters Catflap's shortcuts, so the keys reach the
    /// recorder; when recording ends they register again, and one whose combination was taken
    /// meanwhile is a conflict, as at the start and on a rebind. Here a test hook takes the
    /// panel's combination during recording with a second registration inside the agent's
    /// process, which RegisterEventHotKey refuses while another holds the combination
    /// (eventHotKeyExistsErr). A combination macOS keeps would mean changing this Mac's own
    /// shortcuts, so the in-process registration stands in for another holder. Recording then
    /// stops without a new combination: the panel's shortcut is refused, `ui state` and settings
    /// say conflict, never bound, and the agent keeps running.
    @Test func testAShortcutTakenWhileRecordingIsAConflictWhenRecordingEnds() async throws {
        let agent = try ActionsAgent(platform: true)
        var failure: (any Error)?
        do {
            try await actionsOffPool {
                for key in [Self.panelKey, Self.sendKey] { try agent.writePreference(key, nil) }
                try agent.start(environment: ["CATFLAP_TEST_HOOKS": "on"])
            }
            let first = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(first, "shortcut") == "bound", "the panel's shortcut is registered at the start")
            let early = try await actionsOffPool { try agent.invoke("test-hold-shortcut", ["which": "panel"]) }
            #expect(!early.ok, "a second registration of the registered combination is refused")

            let recording = try await actionsOffPool { try agent.reply("test-press-recorder", ["which": "panel"]) }
            #expect(recording.message == "recording" && recording.state.actions.settingsOpen, "the recorder in settings listens")
            let held = try await actionsOffPool { try agent.invoke("test-hold-shortcut", ["which": "panel"]) }
            #expect(held.ok, "recording unregistered the panel's shortcut, so another registration takes it: \(held.error ?? "")")
            let stopped = try await actionsOffPool { try agent.reply("test-press-recorder", ["which": "panel"]) }
            #expect(stopped.message == "not recording", "the second click stops recording")

            let after = try await actionsOffPool { try agent.request("ui.state").payload }
            print("MacActionsE2E recorder resume: held=\(held.ok) panel=\(stateField(after, "shortcut") ?? "none") settings=\(settingsField(after, "panel_shortcut_state") ?? "none") send=\(stateField(after, "send_shortcut") ?? "none")")
            #expect(stateField(after, "shortcut") == "conflict", "the shortcut refused when recording ends is a conflict, not bound")
            #expect(stateField(after, "shortcut_keys") == Self.panelDefault.description, "it keeps its combination")
            #expect(settingsField(after, "panel_shortcut_state") == "conflict", "settings show the conflict")
            #expect(stateField(after, "send_shortcut") == "bound" && settingsField(after, "send_shortcut_state") == "bound",
                    "the other shortcut registered again")

            // The agent goes on: it answers, and a setting changes.
            let status = try await actionsOffPool { try agent.request("status") }
            #expect(status.ok, "the agent still answers beside the conflict")
            let changed = try await actionsOffPool { try agent.reply("set", ["key": "hover_band", "value": "off"]) }
            #expect(!changed.state.actions.settings.hoverBand, "a settings change beside the conflict")
            _ = try await actionsOffPool { try agent.invoke("test-release-shortcut") }
            _ = try await actionsOffPool { try agent.invoke("settings-close") }
        } catch { failure = error }
        let problems = try await actionsOffPool { agent.close() }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        print("MacActionsE2E recorder resume: agent_exit=\(agent.exitStatus.map { "\($0)" } ?? "none")")
        #expect(agent.exitStatus == 0, "the agent kept running and stops cleanly on SIGTERM")
        if let failure { throw failure }
    }

    // MARK: Don't keep, copied

    /// Waits until the general pasteboard holds `text`; the deadline only guards against a hang.
    private func waitForPasteboard(_ text: String, _ what: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while await MainActor.run(body: { NSPasteboard.general.string(forType: .string) }) != text {
            guard Date() < deadline else { throw ActionsTestError.timeout(what) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `text` sent from `peer` to the panel agent, kept or not; returns its history row on the
    /// panel (`device/id`) once it has arrived.
    private func receive(_ text: String, keep: Bool, from peer: ActionsAgent, on panel: ActionsAgent, to panelID: String) async throws -> String {
        let sent = try await actionsOffPool { try peer.command(["send", "--to", panelID, "--text", text] + (keep ? [] : ["--dont-keep"])) }
        #expect(sent.code == 0, "send from the peer: \(sent.errorText)")
        let id = try ControlJSON.decoder.decode(TransferRecord.self, from: sent.output).id
        let arrived = try await row(on: panel, "the peer's text on the panel") { $0.direction == "received" && $0.id == id }
        #expect(arrived.keep == keep)
        return arrived.deviceID + "/" + arrived.id
    }

    /// `text`, a text that was not kept and that the panel agent put on the clipboard, is marked
    /// concealed, and clipboard history never reads or keeps it. The send-clipboard shortcut
    /// reads the clipboard first, so by its answer the watcher has judged this copy: marked,
    /// which it decides from the types alone, before reading any content, so there is nothing to
    /// send. An ordinary copy after it, once recorded, shows the watcher has gone past it; then
    /// nothing of `text` may be in history or in any file of the agent's data.
    private func expectConcealedAndUnrecorded(_ text: String, on panel: ActionsAgent, _ step: String) async throws {
        let (held, concealed) = await MainActor.run { () -> (Bool, Bool) in
            let board = NSPasteboard.general
            return (board.string(forType: .string) == text, board.types?.contains(.init("org.nspasteboard.ConcealedType")) ?? false)
        }
        #expect(held, "\(step): the text is on the clipboard")
        #expect(concealed, "\(step): it is marked concealed")
        let latest = try await actionsOffPool { try panel.invoke("send-latest") }
        #expect(!latest.ok && latest.error == ClipboardFailure.latestMarked.rawValue,
                "\(step): clipboard history judged it marked, unread: \(latest.ok ? "it was read, recorded and sent" : latest.error ?? "")")
        let barrier = "ordinary copy " + UUID().uuidString
        await MainActor.run {
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(barrier, forType: .string)
        }
        _ = try await actionsOffPool {
            try panel.waitFor("\(step): the ordinary copy in clipboard history") { try panel.clipTexts().contains(barrier) ? true : nil }
        }
        let listed = try await actionsOffPool { try panel.clipTexts() }
        #expect(!listed.contains(text), "\(step): not in clipboard history")
        let files = try await actionsOffPool { panel.filesContaining(text) }
        #expect(files.isEmpty, "\(step): in no file of the agent's data: \(files)")
        print("MacActionsE2E don't-keep copy (\(step)): concealed=\(concealed) sent_by_shortcut=\(latest.ok) recorded=\(listed.contains(text)) files_holding_it=\(files.count)")
    }

    /// Copy of a received text that was not kept (Don't keep on the sender) puts it on the
    /// clipboard marked concealed, so clipboard history never reads or records it: from its row
    /// (the notification's Copy runs the same action), and on arrival with Put received text
    /// on the clipboard on. A kept text stays an ordinary copy, which history records.
    @Test func testDontKeepTextCopiedHereIsConcealedAndNeverRecorded() async throws {
        let saved = try await MainActor.run { try PasteboardSnapshot() }
        var failure: (any Error)?
        do {
            try await withAgents { panel, peer in
                let peer = try #require(peer)
                try await pairFromPanel(panel, peer)
                let panelID = try #require(try await actionsOffPool { try peer.devices().first?.id })

                let copiedText = "not kept, copied " + UUID().uuidString
                let rowID = try await receive(copiedText, keep: false, from: peer, on: panel, to: panelID)
                let copied = try await actionsOffPool { try panel.invoke("copy", ["id": rowID]) }
                #expect(copied.ok, "copy: \(copied.error ?? "")")
                try await expectConcealedAndUnrecorded(copiedText, on: panel, "Copy")

                let on = try await actionsOffPool { try panel.invoke("set", ["key": "received_text_to_clipboard", "value": "on"]) }
                #expect(on.ok, "received text to the clipboard: \(on.error ?? "")")
                let arrivedText = "not kept, arrived " + UUID().uuidString
                _ = try await receive(arrivedText, keep: false, from: peer, on: panel, to: panelID)
                try await waitForPasteboard(arrivedText, "the text that was not kept on the clipboard")
                try await expectConcealedAndUnrecorded(arrivedText, on: panel, "received text to the clipboard")

                let keptText = "kept, arrived " + UUID().uuidString
                _ = try await receive(keptText, keep: true, from: peer, on: panel, to: panelID)
                try await waitForPasteboard(keptText, "the kept text on the clipboard")
                let ordinary = await MainActor.run { !(NSPasteboard.general.types?.contains(.init("org.nspasteboard.ConcealedType")) ?? false) }
                #expect(ordinary, "a kept text is an ordinary copy")
                let recorded = try await actionsOffPool {
                    try panel.waitFor("the kept text in clipboard history") { try panel.clipTexts().contains(keptText) ? true : nil }
                }
                #expect(recorded, "clipboard history records a kept text")
            }
        } catch { failure = error }
        await MainActor.run { saved.restore() }
        if let failure { throw failure }
    }

    /// Presses Copy on the arrival notification of `row` (`device/id`) once it is posted. The
    /// hook enters the function Notification Center's delegate calls, with the userInfo the
    /// agent posted that notification with; a press before it was posted is refused.
    private func pressNotificationCopy(_ row: String, on panel: ActionsAgent, _ step: String) async throws {
        let pressed = try await actionsOffPool {
            try panel.waitFor("\(step): the arrival notification to press") { () -> Bool? in
                try panel.invoke("notification-press", ["id": row, "button": "copy"]).ok ? true : nil
            }
        }
        #expect(pressed, "\(step): Copy pressed on the arrival notification")
    }

    /// The Copy button of an arrival notification: a text that was not kept (Don't keep on
    /// the sender) goes on the clipboard marked concealed, and clipboard history never reads or
    /// records it; a kept text is an ordinary copy, which history records.
    @Test func testNotificationCopyOfATextNotKeptIsConcealedAndNeverRecorded() async throws {
        let saved = try await MainActor.run { try PasteboardSnapshot() }
        var failure: (any Error)?
        do {
            try await withAgents(hooks: true) { panel, peer in
                let peer = try #require(peer)
                try await pairFromPanel(panel, peer)
                let panelID = try #require(try await actionsOffPool { try peer.devices().first?.id })

                let notKept = "not kept, notification copy " + UUID().uuidString
                let notKeptRow = try await receive(notKept, keep: false, from: peer, on: panel, to: panelID)
                try await pressNotificationCopy(notKeptRow, on: panel, "not kept")
                try await waitForPasteboard(notKept, "the text that was not kept, copied from its notification")
                try await expectConcealedAndUnrecorded(notKept, on: panel, "notification Copy")

                let kept = "kept, notification copy " + UUID().uuidString
                let keptRow = try await receive(kept, keep: true, from: peer, on: panel, to: panelID)
                try await pressNotificationCopy(keptRow, on: panel, "kept")
                try await waitForPasteboard(kept, "the kept text, copied from its notification")
                let ordinary = await MainActor.run { !(NSPasteboard.general.types?.contains(.init("org.nspasteboard.ConcealedType")) ?? false) }
                #expect(ordinary, "a kept text copied from its notification is an ordinary copy")
                let recorded = try await actionsOffPool {
                    try panel.waitFor("the kept text in clipboard history") { try panel.clipTexts().contains(kept) ? true : nil }
                }
                #expect(recorded, "clipboard history records a kept text")
                print("MacActionsE2E notification Copy: kept ordinary=\(ordinary) recorded=\(recorded)")
            }
        } catch { failure = error }
        await MainActor.run { saved.restore() }
        if let failure { throw failure }
    }

    // MARK: Several files

    /// Two attached files, one of them gone just before Send: the reply names the file that did
    /// not start and why, the other goes once, and only the one that did not start stays
    /// attached, so Send again sends just that one. Every file arrives exactly once.
    @Test func testTwoAttachmentsOneGoneBeforeSendReportEachFile() async throws {
        try await withAgents { panel, peer in
            let peer = try #require(peer)
            try await pairFromPanel(panel, peer)
            let suffix = String(UUID().uuidString.prefix(6))
            let good = panel.directory.appendingPathComponent("good-\(suffix).txt")
            let gone = panel.directory.appendingPathComponent("gone-\(suffix).txt")
            try Data(("good file " + UUID().uuidString).utf8).write(to: good)
            let goneBytes = Data(("gone file " + UUID().uuidString).utf8)
            try goneBytes.write(to: gone)
            let goodHash = try TransferInbox.hash(good), goneHash = try TransferInbox.hash(gone)
            let attached = try await actionsOffPool { try panel.reply("attach", ["files": good.path + "\n" + gone.path]) }
            #expect(attached.state.ui.attachments == 2)
            try FileManager.default.removeItem(at: gone)

            let first = try await actionsOffPool { try panel.invoke("send") }
            #expect(first.ok, "a send in which one file started is not refused: \(first.error ?? "")")
            let notSent = notSentFiles(first.payload)
            #expect(notSent.map { $0.file } == [gone.path] && notSent.first?.reason == "Cannot read that file.",
                    "the reply names the file that did not start, and why: \(notSent.map { URL(fileURLWithPath: $0.file).lastPathComponent + ": " + $0.reason })")
            let started = (try? first.decode(ActionsReply.self).transfers) ?? []
            #expect(started.count == 1 && started.first?.kind == "file", "the other file started")
            #expect(stateField(first.payload, "attachments") == "1", "only the file that did not start stays attached")
            let line = stateField(first.payload, "send_line") ?? ""
            #expect(line.contains(gone.lastPathComponent), "the panel's line names the file not sent: \(line)")
            _ = try await row(on: peer, "the good file on the peer") { $0.direction == "received" && $0.sha256 == goodHash }

            try goneBytes.write(to: gone)
            let second = try await actionsOffPool { try panel.invoke("send") }
            #expect(second.ok, "Send again: \(second.error ?? "")")
            let again = (try? second.decode(ActionsReply.self).transfers) ?? []
            #expect(again.count == 1, "Send again sends only the file that did not start")
            #expect(stateField(second.payload, "attachments") == "0")
            _ = try await row(on: peer, "the second file on the peer") { $0.direction == "received" && $0.sha256 == goneHash }
            // Every send has ended (its row is ok on the panel), so the peer has all it will get.
            for id in (started + again).map(\.id) {
                _ = try await row(on: panel, "a sent file's row on the panel") { $0.direction == "sent" && $0.id == id }
            }
            let received = try await actionsOffPool { try peer.history() }.filter { $0.direction == "received" }
            let counts = (received.filter { $0.sha256 == goodHash }.count, received.filter { $0.sha256 == goneHash }.count)
            #expect(counts.0 == 1 && counts.1 == 1, "each file arrived exactly once: good=\(counts.0) second=\(counts.1)")
            print("MacActionsE2E two attachments: first_started=\(started.count) not_sent=\(notSent.count) attached_after=\(stateField(first.payload, "attachments") ?? "none") again=\(again.count) arrived good=\(counts.0) second=\(counts.1)")
        }
    }

    // MARK: Lists that cannot be read

    /// The panel's reads of its lists fail while the store changes: the panel still lists the
    /// device, the send button still names it, the clipboard and history rows stay as they were,
    /// and `ui state` names the lists it could not read. Readable again, the next read shows
    /// the change and names none.
    @Test func testAFailedListReadKeepsTheLastLists() async throws {
        try await withAgents(hooks: true) { panel, peer in
            let peer = try #require(peer)
            try await pairFromPanel(panel, peer)
            let peerName = try #require(try await actionsOffPool { try panel.devices().first?.name })
            // The field filters the clipboard list to this test's own rows, and gives the send
            // button something to name.
            let token = "kept" + UUID().uuidString.prefix(8).lowercased()
            let first = try await actionsOffPool { try panel.command(["clip", "add", "--text", token + " listed before"]) }
            #expect(first.code == 0, "clip add: \(first.errorText)")
            _ = try await actionsOffPool { try panel.reply("type", ["text": token]) }
            let before = try await actionsOffPool {
                try panel.waitFor("the open panel to list the device and the clipboard row") { () -> Data? in
                    let payload = try panel.request("ui.state").payload
                    let shown = stateField(payload, "devices") == "1" && stateField(payload, "list") == "clipboard" && stateField(payload, "rows") == "1"
                    return shown ? payload : nil
                }
            }
            #expect(stateField(before, "send_label")?.hasSuffix(" to \(peerName)") == true, "the send button names the device")

            let all = ["devices", "clipboard", "history"]
            let faulted = try await actionsOffPool { try panel.invoke("test-fail-reads", ["lists": all.joined(separator: ",")]) }
            #expect(faulted.ok, "test-fail-reads: \(faulted.error ?? "")")
            let added = try await actionsOffPool { try panel.command(["clip", "add", "--text", token + " added while unreadable"]) }
            #expect(added.code == 0, "clip add: \(added.errorText)")
            #expect(try await actionsOffPool { try panel.clipTexts() }.contains(token + " added while unreadable"), "the agent has the new row")
            // The panel reads its lists again after the change, and they still cannot be read.
            let read = try await actionsOffPool { try panel.invoke("test-fail-reads", ["lists": all.joined(separator: ",")]) }
            #expect(read.ok, "test-fail-reads: \(read.error ?? "")")
            let during = read.payload
            #expect(stateField(during, "devices") == "1", "the panel lists \(stateField(during, "devices") ?? "no") paired devices")
            #expect(stateField(during, "send_label") == stateField(before, "send_label"), "the send button says: \(stateField(during, "send_label") ?? "nothing")")
            #expect(stateField(during, "rows") == "1" && stateField(during, "clipboard_rows") == stateField(before, "clipboard_rows"),
                    "clipboard rows: \(stateField(during, "rows") ?? "none") of this test, \(stateField(during, "clipboard_rows") ?? "none") in all, \(stateField(before, "clipboard_rows") ?? "none") before")
            #expect(stateField(during, "history_rows") == stateField(before, "history_rows"), "history rows: \(stateField(during, "history_rows") ?? "none")")
            #expect(unreadableLists(during) == all, "ui state names: \(unreadableLists(during)?.joined(separator: ",") ?? "no field")")

            // Readable again: the next read shows the row added meanwhile, and names no list.
            let cleared = try await actionsOffPool { try panel.invoke("test-fail-reads", ["lists": ""]) }
            #expect(cleared.ok, "test-fail-reads: \(cleared.error ?? "")")
            let after = cleared.payload
            #expect(stateField(after, "rows") == "2", "clipboard rows of this test once readable: \(stateField(after, "rows") ?? "none")")
            #expect(stateField(after, "devices") == "1" && stateField(after, "send_label") == stateField(before, "send_label"), "the device once readable")
            #expect(unreadableLists(after) == [], "ui state names: \(unreadableLists(after)?.joined(separator: ",") ?? "no field")")
            print("MacActionsE2E unreadable lists: devices_during=\(stateField(during, "devices") ?? "none") rows_during=\(stateField(during, "rows") ?? "none") unreadable_during=\(unreadableLists(during)?.joined(separator: ",") ?? "no field") rows_after=\(stateField(after, "rows") ?? "none") unreadable_after=\(unreadableLists(after)?.joined(separator: ",") ?? "no field")")
        }
    }

    /// Send while the paired devices cannot be read: nothing is sent, the panel says why, and
    /// the field and the attached file stay. Readable again, Send sends the file and send-text
    /// sends what the field still holds.
    @Test func testASendWhileThePairedDevicesCannotBeReadSendsNothing() async throws {
        try await withAgents(hooks: true) { panel, peer in
            let peer = try #require(peer)
            try await pairFromPanel(panel, peer)
            let file = panel.directory.appendingPathComponent("stays-\(UUID().uuidString.prefix(6)).txt")
            try Data(("stays attached " + UUID().uuidString).utf8).write(to: file)
            let expected = try TransferInbox.hash(file)
            let typed = "stays in the field " + UUID().uuidString
            let attached = try await actionsOffPool { try panel.reply("attach", ["files": file.path]) }
            #expect(attached.state.ui.attachments == 1, "the file is attached")
            _ = try await actionsOffPool { try panel.reply("type", ["text": typed]) }
            let unreadable = "Catflap could not read your paired devices. Try again."
            let faulted = try await actionsOffPool { try panel.invoke("test-fail-reads", ["lists": "devices"]) }
            #expect(faulted.ok, "test-fail-reads: \(faulted.error ?? "")")

            let pressed = try await actionsOffPool { try panel.invoke("send") }
            #expect(!pressed.ok && pressed.error == unreadable, "Send answered: \(pressed.error ?? "it sent")")
            let typedSend = try await actionsOffPool { try panel.invoke("send-text") }
            #expect(!typedSend.ok && typedSend.error == unreadable, "send-text answered: \(typedSend.error ?? "it sent")")
            let state = try await actionsOffPool { try panel.request("ui.state").payload }
            #expect(stateField(state, "attachments") == "1", "the attached file stays")
            let line = stateField(state, "send_line") ?? ""
            #expect(line.hasSuffix(unreadable), "the panel's line says: \(line)")
            let sent = try await actionsOffPool { try panel.history() }.filter { $0.direction == "sent" }.count
            #expect(sent == 0, "\(sent) sends started")

            // Readable again: Send sends the file, and send-text the text the field kept.
            let cleared = try await actionsOffPool { try panel.invoke("test-fail-reads", ["lists": ""]) }
            #expect(cleared.ok, "test-fail-reads: \(cleared.error ?? "")")
            let again = try await actionsOffPool { try panel.invoke("send") }
            #expect(again.ok, "Send once readable: \(again.error ?? "")")
            let arrived = try await row(on: peer, "the attached file on the peer") { $0.direction == "received" && $0.sha256 == expected }
            let text = try await actionsOffPool { try panel.invoke("send-text") }
            #expect(text.ok, "send-text once readable: \(text.error ?? "")")
            let typedArrived = try await row(on: peer, "the field's text on the peer") { $0.direction == "received" && $0.text == typed }
            print("MacActionsE2E unreadable devices: send=\(pressed.error == unreadable ? "refused" : pressed.error ?? "sent") send_text=\(typedSend.error == unreadable ? "refused" : typedSend.error ?? "sent") attachments_kept=\(stateField(state, "attachments") ?? "none") started=\(sent) file_after=\(arrived.status) text_after=\(typedArrived.status)")
        }
    }

    // MARK: Opening the app again

    /// Opening Catflap.app while it runs, as Finder does (`open` on the running app), brings up
    /// the running agent's panel, focused, and starts no second agent. The arguments given to
    /// `open` reach only a newly started copy, which would find this agent's data folder locked
    /// and stop, so no default data folder is ever used.
    @Test func testOpeningTheRunningAppShowsItsPanelFocused() async throws {
        let installed = try await actionsOffPool { try InstalledApp.make() }
        defer { installed.remove() }
        let agent = try ActionsAgent(platform: true, executable: installed.binary, domain: Self.appDomain)
        var failure: (any Error)?
        do {
            try await actionsOffPool { try agent.start() }
            let before = try await actionsOffPool { try agent.request("ui.state").payload }
            #expect(stateField(before, "visible") == "0", "the panel starts closed")
            let opened = try await actionsOffPool {
                try actionsRun("/usr/bin/open", [installed.app.path, "--args", "agent", "--data-dir", agent.directory.path], in: agent.directory, seconds: 60)
            }
            #expect(opened.code == 0, "open: \(opened.errorText)")
            // AppKit's reopen event is counted once the panel has been shown for it.
            let after = try await actionsOffPool {
                try agent.waitFor("the running app's reopen event", seconds: 30) { () -> Data? in
                    let payload = try agent.request("ui.state").payload
                    return (stateField(payload, "reopens").flatMap { Int($0) } ?? 0) >= 1 ? payload : nil
                }
            }
            #expect(stateField(after, "mode") == "focused" && stateField(after, "has_focus") == "1", "the panel is open and focused")
            let running = await MainActor.run { NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Self.appDomain }.count }
            #expect(running == 1, "one Catflap runs: \(running)")
            #expect(try await actionsOffPool { try agent.request("status") }.ok, "the agent still answers")
            print("MacActionsE2E reopen: open_exit=\(opened.code) mode=\(stateField(after, "mode") ?? "none") has_focus=\(stateField(after, "has_focus") ?? "none") running=\(running)")
            _ = try await actionsOffPool { try agent.invoke("hide") }
        } catch { failure = error }
        let problems = try await actionsOffPool { agent.close() }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }
}
}
#endif
