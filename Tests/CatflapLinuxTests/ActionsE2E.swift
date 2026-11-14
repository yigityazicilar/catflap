import CatflapCore
import Foundation
import XCTest

/// The panel's actions end to end, in a nested KWin with a second agent to send to: each
/// `ui invoke` action and the controls behind it, pairing and unpairing from the panel, the
/// settings across a restart, notifications on arrival, the tray item, the file manager's
/// menu and start at login.
final class LinuxActionsE2E: XCTestCase {
    private func receivedText(_ text: String, _ session: ActionsSession, peer: Bool) throws -> Bool {
        try session.eventually(60) {
            try session.history(peer: peer).contains { $0.direction == "received" && $0.text == text && $0.status == "ok" }
        }
    }

    private func sentText(_ text: String, _ session: ActionsSession) throws -> Bool {
        try session.eventually(60) {
            try session.history().contains { $0.direction == "sent" && $0.text == text && $0.status == "ok" }
        }
    }

    func testSendTextClipAttachAndCopyEachLeaveTheirHistoryRows() throws {
        let session = try ActionsSession()
        try session.start()
        try session.confirmShortcuts()
        try session.pairWithCommandLine()
        let peerName = try XCTUnwrap(session.devices().first?.name)

        // send-text, with the text given, as the field would hold it.
        let given = "sent from the panel with its text given"
        let first = try session.invoke("send-text", ["text": given])
        XCTAssertTrue(first.ok, first.error ?? "")
        XCTAssertTrue(try sentText(given, session))
        XCTAssertTrue(try receivedText(given, session, peer: true))

        // send-text from the command line: what was typed into the focused panel's field.
        _ = try session.catflap(["toggle"])
        XCTAssertTrue(try session.eventually { try session.describe().hasFocus })
        try session.type("typed into the field")
        XCTAssertTrue(try session.eventually { try session.describe().field == "typed into the field" })
        XCTAssertTrue(try session.describe().sendLabel.hasSuffix("to \(peerName)"))
        _ = try session.catflap(["ui", "invoke", "send-text"])
        XCTAssertTrue(try sentText("typed into the field", session))
        XCTAssertTrue(try receivedText("typed into the field", session, peer: true))
        // The field is ready for the next send.
        XCTAssertTrue(try session.eventually { try session.describe().field.isEmpty })

        // send-clip: the newest clipboard item.
        _ = try session.catflap(["clip", "add", "--text", "a clipboard line to send"])
        _ = try session.catflap(["ui", "invoke", "send-clip"])
        XCTAssertTrue(try sentText("a clipboard line to send", session))
        XCTAssertTrue(try receivedText("a clipboard line to send", session, peer: true))

        // attach: the file is attached and the panel focused; the send button sends it.
        let file = session.root.appendingPathComponent("home/report.txt")
        let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try body.write(to: file)
        let expected = try TransferInbox.hash(file)
        let attached = try session.invoke("attach", ["files": file.path])
        XCTAssertTrue(attached.ok, attached.error ?? "")
        XCTAssertEqual(try attached.decode(ActionsResult.self).attachments, ["report.txt"])
        let description = try session.describe()
        XCTAssertEqual(description.mode, "focused")
        XCTAssertEqual(description.attachments, ["report.txt"])
        XCTAssertEqual(description.sendLabel, "Send \"report.txt\" to \(peerName)")
        XCTAssertTrue(description.controls.contains { $0.label == "Remove attachment report.txt" })
        _ = try session.catflap(["ui", "invoke", "send"])
        XCTAssertTrue(try session.eventually(60) {
            try session.history(peer: true).contains { $0.direction == "received" && $0.status == "ok" && $0.sha256 == expected }
        })
        let row = try XCTUnwrap(try session.history(peer: true).first { $0.sha256 == expected })
        XCTAssertEqual(try TransferInbox.hash(URL(fileURLWithPath: try XCTUnwrap(row.path))), expected)
        XCTAssertTrue(try session.history().contains { $0.direction == "sent" && $0.sha256 == expected && $0.status == "ok" })
        XCTAssertTrue(try session.eventually { try session.describe().attachments.isEmpty })

        // copy: text that arrives is not put on the clipboard by itself; Copy puts it there.
        let arriving = "copy me from the history"
        _ = try session.catflap(["send", "--text", arriving], peer: true, seconds: 60)
        XCTAssertTrue(try receivedText(arriving, session, peer: false))
        XCTAssertNotEqual(session.paste(), arriving)
        let copied = try session.catflap(["ui", "invoke", "copy"])
        XCTAssertNotNil(try ControlJSON.decoder.decode(ActionsResult.self, from: copied).copied)
        XCTAssertTrue(session.eventually { session.paste() == arriving })

        // delete: the row goes from this device's history.
        let received = try XCTUnwrap(try session.history().first { $0.text == arriving })
        XCTAssertTrue(try session.invoke("delete", ["id": received.deviceID + "/" + received.id]).ok)
        XCTAssertTrue(try session.eventually { try !session.history().contains { $0.id == received.id } })
    }

    func testArrivalNotifiesQuietlyWithCopyAndShowInFolder() throws {
        let session = try ActionsSession()
        try session.start()
        try session.confirmShortcuts()
        try session.pairWithCommandLine()
        let senderName = try XCTUnwrap(session.devices().first?.name)

        let text = "a quiet arrival"
        _ = try session.catflap(["send", "--text", text], peer: true, seconds: 60)
        var note: [String: Any] = [:]
        XCTAssertTrue(session.eventually(30) {
            note = session.notifications().first { $0["title"] as? String == "Text from \(senderName)" } ?? [:]
            return !note.isEmpty
        })
        XCTAssertEqual(note["actions"] as? [String], ["copy", "Copy"])
        XCTAssertEqual(note["urgency"] as? Int, 0)
        XCTAssertEqual(note["suppress_sound"] as? Bool, true)
        XCTAssertEqual(note["desktop_entry"] as? String, "io.github.yigityazicilar.Catflap")
        XCTAssertEqual(note["body"] as? String, text)
        // Not on the clipboard until the person asks.
        XCTAssertNotEqual(session.paste(), text)
        try session.clickNotification(try XCTUnwrap(note["id"] as? Int), "copy")
        XCTAssertTrue(session.eventually { session.paste() == text })

        // A file: "Show in folder".
        let file = session.root.appendingPathComponent("peer-photo.bin")
        try Data(repeating: 7, count: 4096).write(to: file)
        _ = try session.catflap(["send", "--file", file.path], peer: true, seconds: 60)
        XCTAssertTrue(session.eventually(30) {
            session.notifications().contains {
                $0["title"] as? String == "File from \(senderName)" && $0["actions"] as? [String] == ["reveal", "Show in folder"]
                    && ($0["body"] as? String)?.hasPrefix("peer-photo.bin") == true
            }
        })

        // A text that was sent with "don't keep": the notification still offers Copy, and the
        // copy is marked so clipboard histories do not record it.
        let secret = "do not keep this one"
        _ = try session.catflap(["send", "--text", secret, "--dont-keep"], peer: true, seconds: 60)
        var kept: [String: Any] = [:]
        XCTAssertTrue(session.eventually(30) {
            kept = session.notifications().last { ($0["body"] as? String)?.hasPrefix("Not kept") == true } ?? [:]
            return !kept.isEmpty
        })
        try session.clickNotification(try XCTUnwrap(kept["id"] as? Int), "copy")
        XCTAssertTrue(session.eventually { session.paste() == secret })
        XCTAssertTrue(session.paste(types: true)?.contains("x-kde-passwordManagerHint") == true)
        // This agent's own clipboard history skipped it.
        let clips = String(decoding: try session.catflap(["clip", "list"]), as: UTF8.self)
        XCTAssertFalse(clips.contains(Data(secret.utf8).base64EncodedString()))

        // With the setting on, received text goes to the clipboard by itself.
        XCTAssertTrue(try session.invoke("set", ["key": "received_text_to_clipboard", "value": "on"]).ok)
        let automatic = "straight to the clipboard"
        _ = try session.catflap(["send", "--text", automatic], peer: true, seconds: 60)
        XCTAssertTrue(session.eventually(30) { session.paste() == automatic })
    }

    func testPairingFromThePanelShowsTheDigitsAndUnpairingRemovesTheDevice() throws {
        let session = try ActionsSession()
        try session.start()
        try session.confirmShortcuts()

        XCTAssertTrue(try session.invoke("pair").ok)
        XCTAssertEqual(try session.describe().page, "pair")
        XCTAssertTrue(try session.invoke("pair-start").ok)
        XCTAssertTrue(try session.eventually(60) { try session.describe().pairing.step == "code" })
        XCTAssertTrue(try session.describe().pairing.hasCode)
        // The code goes to the clipboard marked, so no clipboard history records it.
        XCTAssertTrue(try session.invoke("pair-copy-code").ok)
        var code = ""
        XCTAssertTrue(session.eventually {
            code = session.paste() ?? ""
            return code.count > 100
        })
        XCTAssertTrue(session.paste(types: true)?.contains("x-kde-passwordManagerHint") == true)
        let clips = String(decoding: try session.catflap(["clip", "list"]), as: UTF8.self)
        XCTAssertFalse(clips.contains(String(code.prefix(40))))

        _ = try session.catflap(["pair", "join", code], peer: true, seconds: 60)
        var peerStatus = PairingStatus(state: .idle)
        XCTAssertTrue(try session.eventually(60) {
            peerStatus = try ControlJSON.decoder.decode(PairingStatus.self, from: session.catflap(["pair", "status"], peer: true))
            return peerStatus.state == .confirm
        })
        XCTAssertTrue(try session.eventually(30) { try session.describe().pairing.step == "confirm" })
        let shown = try session.describe().pairing
        // Both show the same six digits, each with the other device's name.
        let sameDigits = shown.digits != nil && shown.digits == peerStatus.digits
        XCTAssertTrue(sameDigits)
        XCTAssertEqual(shown.digits?.count, 6)
        XCTAssertNotNil(shown.peerName)
        XCTAssertTrue(try session.invoke("pair-confirm").ok)
        _ = try session.catflap(["pair", "confirm"], peer: true)
        XCTAssertTrue(try session.eventually(60) { try session.describe().pairing.step == "done" })
        XCTAssertTrue(try session.eventually(30) { try session.devices().count == 1 && session.devices(peer: true).count == 1 })
        let device = try XCTUnwrap(session.devices().first)

        // Dolphin's menu lists the device by name and sends by id; the file is executable.
        let menu = session.root.appendingPathComponent("share/kio/servicemenus/io.github.yigityazicilar.Catflap.desktop")
        XCTAssertTrue(session.eventually {
            ((try? String(contentsOf: menu, encoding: .utf8)) ?? "").contains("send --to \(device.id) --file %f")
        })
        let contents = try String(contentsOf: menu, encoding: .utf8)
        XCTAssertTrue(contents.contains("X-KDE-Submenu=Send with Catflap"))
        XCTAssertTrue(contents.contains("Name=\(DesktopName.clean(device.name))"))
        XCTAssertTrue(contents.contains("Name=Choose in Catflap…"))
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: menu.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o111, 0o111)
        // A KDE service menu (Type=Service, all/allfiles) is KDE's format, not an application
        // entry, so desktop-file-validate does not apply to it; packaging/linux's entry passes it.

        // Remove from the panel: the device goes here, and the menu no longer lists it.
        XCTAssertTrue(try session.invoke("remove", ["device": device.id]).ok)
        XCTAssertTrue(try session.eventually(30) { try session.devices().isEmpty })
        XCTAssertTrue(session.eventually {
            !((try? String(contentsOf: menu, encoding: .utf8)) ?? "send --to").contains("send --to")
        })
        // The other device still lists this one; a send from it now fails.
        let refused = try session.run(session.executable.path,
                                      ["send", "--text", "after removal", "--data-dir", session.peerData.path, "--json"],
                                      seconds: 90, allowFailure: true)
        XCTAssertTrue(String(decoding: refused, as: UTF8.self).contains("\"ok\":false"))
        XCTAssertFalse(try session.history().contains { $0.text == "after removal" })
    }

    func testSettingsSurviveARestartAndStartAtLoginWritesTheAutostartEntry() throws {
        let session = try ActionsSession()
        try session.start(peer: false)
        try session.confirmShortcuts()
        let inbox = session.root.appendingPathComponent("elsewhere").path
        for (key, value) in [("hover_band", "off"), ("received_text_to_clipboard", "on"), ("inbox", inbox),
                             ("relay", "relay.example.test"), ("start_at_login", "on")] {
            let response = try session.invoke("set", ["key": key, "value": value])
            XCTAssertTrue(response.ok, response.error ?? key)
        }
        let expected = try session.describe().settings
        XCTAssertFalse(expected.hoverBand)
        XCTAssertTrue(expected.receivedTextToClipboard)
        XCTAssertEqual(expected.inbox, inbox)
        XCTAssertEqual(expected.relay, "relay.example.test")
        XCTAssertTrue(expected.startAtLogin)
        let autostart = session.root.appendingPathComponent("config/autostart/io.github.yigityazicilar.Catflap.desktop")
        let entry = try String(contentsOf: autostart, encoding: .utf8)
        XCTAssertTrue(entry.contains("Exec=") && entry.contains(" agent"))
        XCTAssertTrue(entry.contains(URL(fileURLWithPath: session.executable.path).resolvingSymlinksInPath().lastPathComponent))
        let validation = try session.run("/usr/bin/desktop-file-validate", [autostart.path], allowFailure: true)
        XCTAssertFalse(String(decoding: validation, as: UTF8.self).contains("error:"))
        // With the band off, resting on it does not open the panel.
        _ = try session.invoke("simulate-hover")
        XCTAssertEqual(try session.describe().mode, "hidden")

        try session.restartPanelAgent()
        XCTAssertEqual(try session.describe().settings, expected)
        _ = try session.invoke("simulate-hover")
        XCTAssertEqual(try session.describe().mode, "hidden")
        // The Inbox setting is the one the transfer service reads at start.
        let stored = String(decoding: try session.run("/usr/bin/sqlite3", [session.data.appendingPathComponent("store.sqlite").path,
                                                                              "SELECT value FROM settings WHERE key='inbox'"]), as: UTF8.self)
        XCTAssertEqual(stored.trimmingCharacters(in: .whitespacesAndNewlines), inbox)

        XCTAssertTrue(try session.invoke("set", ["key": "start_at_login", "value": "off"]).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: autostart.path))
        XCTAssertTrue(try session.invoke("set", ["key": "hover_band", "value": "on"]).ok)
        XCTAssertEqual(try ControlJSON.decoder.decode(UIState.self, from: session.catflap(["ui", "invoke", "simulate-hover"])).mode, "hover")
        // A refused value says why and changes nothing.
        let refused = try session.invoke("set", ["key": "inbox", "value": "relative/path"])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(try session.describe().settings.inbox, inbox)
    }

    func testDropAndPasteAttachFilesAndLeaveThePanelFocused() throws {
        let session = try ActionsSession()
        try session.start(peer: false)
        try session.confirmShortcuts()
        let file = session.root.appendingPathComponent("home/dropped.txt")
        try Data("dropped".utf8).write(to: file)
        XCTAssertEqual(try ControlJSON.decoder.decode(UIState.self, from: session.catflap(["ui", "invoke", "simulate-drag"])).mode, "drag")
        let dropped = try session.invoke("simulate-drop", ["files": file.absoluteString])
        XCTAssertEqual(try dropped.decode(UIState.self).mode, "focused")
        XCTAssertTrue(try session.eventually { try session.describe().hasFocus })
        XCTAssertEqual(try session.describe().attachments, ["dropped.txt"])
        // Without files a drop still closes the panel, as before.
        _ = try session.invoke("hide")
        _ = try session.catflap(["ui", "invoke", "simulate-drag"])
        XCTAssertEqual(try session.invoke("simulate-drop").decode(UIState.self).mode, "hidden")

        // Pasting files into the focused panel attaches them.
        let pasted = session.root.appendingPathComponent("home/pasted.txt")
        try Data("pasted".utf8).write(to: pasted)
        try session.launch("/usr/bin/wl-copy", ["--foreground", "--type", "text/uri-list", pasted.absoluteString])
        _ = try session.catflap(["toggle"])
        XCTAssertTrue(try session.eventually { try session.describe().hasFocus })
        try session.input("down \(EvdevKey.ctrl)", "key \(EvdevKey.v)", "up \(EvdevKey.ctrl)")
        XCTAssertTrue(try session.eventually { try session.describe().attachments.contains("pasted.txt") })
        XCTAssertEqual(try session.describe().field, "")

        // Attach without files opens the system file picker through the desktop portal. The
        // portal's GTK backend serves the file chooser here: KDE's backend shows an error dialog
        // in this nested session. Choosing a file in the picker is checked by hand (H2): typed
        // keys did not choose one in this session.
        _ = try session.catflap(["ui", "invoke", "attach"])
        var dialog: ActionsPlaced?
        XCTAssertTrue(try session.eventually(30) {
            dialog = try session.windows().first { $0.caption.contains("Attach files") }
            return dialog != nil
        })
        XCTAssertEqual(try session.describe().mode, "focused")
        // The panel steps aside while the picker is open, so it neither covers it nor keeps the keyboard.
        XCTAssertFalse(try session.describe().visible)
        // A click on the dialog gives it the keyboard, as the person's would.
        if let dialog { try session.input("move \(dialog.x + dialog.w / 2) \(dialog.y + dialog.h / 2)", "wait 100", "click", "wait 500") }
        try session.input("key \(EvdevKey.escape)")
        // Cancelled: the panel comes back focused, with what was attached before and nothing more.
        XCTAssertTrue(try session.eventually(30) { let d = try session.describe(); return d.visible && d.hasFocus })
        XCTAssertEqual(try session.describe().attachments, ["dropped.txt", "pasted.txt"])
        XCTAssertFalse(try session.windows().contains { $0.caption.contains("Attach files") })
        XCTAssertEqual(try session.describe().mode, "focused")
    }

    func testTrayItemOpensThePanelInTheCornerAndRefusalsNotify() throws {
        let session = try ActionsSession()
        try session.start(peer: false)
        try session.confirmShortcuts()
        var service = ""
        XCTAssertTrue(session.eventually {
            service = session.events().first { $0["event"] as? String == "tray" }?["service"] as? String ?? ""
            return !service.isEmpty
        })
        XCTAssertTrue(try session.eventually { try session.describe().tray == "registered" })
        let icon = String(decoding: try session.run("/usr/bin/busctl", ["--user", "get-property", service, "/StatusNotifierItem",
                                                                         "org.kde.StatusNotifierItem", "IconName"]), as: UTF8.self)
        XCTAssertTrue(icon.contains("io.github.yigityazicilar.Catflap-idle-symbolic"))
        let menu = String(decoding: try session.run("/usr/bin/busctl", ["--user", "get-property", service, "/StatusNotifierItem",
                                                                         "org.kde.StatusNotifierItem", "ItemIsMenu"]), as: UTF8.self)
        XCTAssertTrue(menu.contains("false"))

        for method in ["Activate", "ContextMenu"] {
            try session.run("/usr/bin/busctl", ["--user", "call", service, "/StatusNotifierItem", "org.kde.StatusNotifierItem", method, "ii", "0", "0"])
            XCTAssertTrue(try session.eventually { try session.describe().mode == "focused" })
            let description = try session.describe()
            XCTAssertEqual(description.openedFrom, "tray")
            XCTAssertEqual(description.placement.anchor, "bottom-right")
            let panel = try XCTUnwrap(try session.panelWindow())
            XCTAssertEqual(panel.x + panel.w, ActionsSession.width - 8)
            XCTAssertEqual(panel.y + panel.h, ActionsSession.height - 8)
            _ = try session.invoke("hide")
            XCTAssertTrue(try session.eventually { try session.describe().mode == "hidden" })
        }
        // The hotkey still opens it at the top centre.
        _ = try session.catflap(["toggle"])
        XCTAssertEqual(try session.describe().placement.anchor, "top")
        XCTAssertEqual(try session.describe().openedFrom, "top")
        _ = try session.invoke("hide")

        // The send-clipboard shortcut refuses with a notification, in the agent's own words. It
        // never falls back to an older row: whatever the session's clipboard held at start-up
        // was not copied since the agent started, or was not something history records.
        let fresh = try session.invoke("send-latest")
        XCTAssertFalse(fresh.ok)
        XCTAssertFalse((fresh.error ?? "").isEmpty)
        XCTAssertFalse(try session.history().contains { $0.direction == "sent" })
        XCTAssertTrue(session.eventually {
            session.notifications().contains { $0["title"] as? String == "Nothing sent" && ($0["body"] as? String) == fresh.error }
        })
        _ = try session.catflap(["clip", "pause", "on"])
        let refused = try session.invoke("send-latest")
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(session.eventually {
            session.notifications().contains { $0["title"] as? String == "Nothing sent" && ($0["body"] as? String) == refused.error }
        })
        XCTAssertTrue(try session.eventually {
            let icon = String(decoding: try session.run("/usr/bin/busctl", ["--user", "get-property", service, "/StatusNotifierItem",
                                                                             "org.kde.StatusNotifierItem", "IconName"]), as: UTF8.self)
            return icon.contains("problem")
        })
    }
}

/// How a device name appears in a desktop entry (the agent's own rule).
enum DesktopName {
    static func clean(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(cleaned)).replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return value.count > 64 ? String(value.prefix(64)) + "…" : value
    }
}
