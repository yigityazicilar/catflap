import CatflapCore
import Foundation
import Testing

struct ControlJSONTests {
    @Test func testJSONUsesSnakeCaseAndISO8601() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        var configuration = PairingConfiguration()
        configuration.name = "Test device"
        let pairing = await PairingService.install(on: runtime, configuration: configuration)
        do {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try await runtime.store.saveDevice(DeviceRecord(id: "peer", name: "Peer", clientPublicKey: "unused",
                address: "unused", pairSecret: Data(), build: "test", pairedAt: date, lastSentAt: date))
            try await runtime.store.saveHistory(HistoryRecord(deviceID: "peer", timestamp: date,
                direction: "sent", kind: "text", size: 4, status: "ok", text: "test"))
            _ = try await pairing.start()
            let deadline = ContinuousClock.now + .seconds(30)
            while await pairing.currentStatus().state == .starting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let waiting = await pairing.currentStatus().state == .waiting
            #expect(waiting)
            var timestamps = Set<String>()
            for command in ["status", "devices", "history", "pair.status", "ui.state"] {
                let response = await runtime.handle(.init(command))
                #expect(response.ok)
                let object = try JSONSerialization.jsonObject(with: response.payload)
                walk(object, timestamps: &timestamps)
                // The envelope is part of the control protocol too.
                let envelope = try JSONSerialization.jsonObject(with: ControlJSON.encoder.encode(response)) as? [String: Any]
                #expect(envelope?["exit_code"] as? Int == 0)
                if let envelope { walk(envelope, timestamps: &timestamps) }
                let decoded = try ControlJSON.decoder.decode(ControlResponse.self, from: ControlJSON.encoder.encode(response))
                #expect(decoded.payload == response.payload)
                switch command {
                case "devices": #expect(try decoded.decode([DeviceSummary].self).first?.lastSentAt == date)
                case "history": #expect(try decoded.decode([HistoryRecord].self).first?.deviceID == "peer")
                case "pair.status": #expect(try decoded.decode(PairingStatus.self).state == .waiting)
                default: break
                }
            }
            let check = try ControlResponse(value: PairingService.CheckStatus(state: "ok"))
            walk(try JSONSerialization.jsonObject(with: check.payload), timestamps: &timestamps)
            #expect(timestamps == ["paired_at", "last_sent_at", "timestamp", "expires_at"])
        } catch {
            _ = await pairing.decline()
            await runtime.stop()
            throw error
        }
        _ = await pairing.decline()
        await runtime.stop()
    }

    private func walk(_ value: Any, timestamps: inout Set<String>) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                #expect(key.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil)
                if key == "timestamp" || key.hasSuffix("_at") || key.hasSuffix("At") {
                    timestamps.insert(key)
                    let valid = (child as? String)?.range(
                        of: "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$", options: .regularExpression) != nil
                    #expect(valid)
                }
                walk(child, timestamps: &timestamps)
            }
        } else if let array = value as? [Any] {
            for child in array { walk(child, timestamps: &timestamps) }
        }
    }
}
