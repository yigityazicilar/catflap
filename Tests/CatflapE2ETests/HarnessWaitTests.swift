import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Scripted observations prove wait/stop control flow, not Foundation or kernel race timing.
private final class ChildWaitScript {
    var time: TimeInterval = 0
    var foundation: Int32?
    var observation: ChildObservation = .ended(collected: false)
    var collectedStatus: Int32? = 0
    var collections = 0
    var signals: [Int32] = []
    var notes: [String] = []
    var afterPause: (() -> Void)?
    var beforeObserve: (() -> Void)?
    var operations: ChildProcessOperations {
        ChildProcessOperations(
            foundationStatus: { self.foundation },
            observe: { self.beforeObserve?(); return self.observation },
            collect: { self.collections += 1; return self.collectedStatus },
            now: { self.time },
            pause: { self.time += 0.25; self.afterPause?() },
            signal: { self.signals.append($0) },
            note: { self.notes.append($0) })
    }
    func agent() throws -> AgentHarness {
        let agent = try AgentHarness()
        agent.process = Process()
        agent.stopOperations = operations
        return agent
    }
}

@Suite struct HarnessWaitTests {
    @Test(arguments: [Int32(0), 23, SIGKILL])
    func testFoundationExitVerdict(status: Int32) throws {
        let script = ChildWaitScript()
        script.foundation = status
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == (status == 0 ? 0 : 1))
        #expect(script.collections == 0)
        #expect(script.signals.isEmpty)
        agent.stop { faults.append($0) }
        #expect(faults.count == (status == 0 ? 0 : 1))
    }

    @Test(arguments: [Int32(0), 23 << 8, SIGKILL, SIGKILL | 0x80])
    func testStaleFoundationUsesNonblockingStatus(raw: Int32) throws {
        let script = ChildWaitScript()
        script.collectedStatus = childExitStatus(raw)
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == (raw == 0 ? 0 : 1))
        #expect(script.collections == 1)
        #expect(script.signals.isEmpty)
        #expect(script.notes.count == 1)
        #expect(script.time <= 7)
    }

    @Test(arguments: [true, false])
    func testLostStatusIsAFaultWithoutSignalingEndedPID(alreadyCollected: Bool) throws {
        let script = ChildWaitScript()
        script.observation = .ended(collected: alreadyCollected)
        // false models a collector winning between observation and nonblocking collection.
        script.collectedStatus = nil
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == 1, "unknown status must not be accepted as a clean exit")
        #expect(faults.first?.contains("exit status was lost") == true)
        #expect(script.collections == (alreadyCollected ? 0 : 1))
        #expect(script.signals.isEmpty)
        agent.stop { faults.append($0) }
        #expect(faults.count == 1)
    }

    @Test func testObservationErrorIsNotALiveTimeoutOrPermissionToSignal() throws {
        let script = ChildWaitScript()
        script.observation = .failed(EIO)
        #expect(waitForEnd(of: Process(), limit: 2, operations: script.operations) == .observationFailed(EIO))
        #expect(script.time == 2)
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == 2)
        #expect(faults.allSatisfy { $0.contains("observation failed") })
        #expect(script.signals.isEmpty)
        #expect(script.collections == 0)
    }

    @Test func testTransientObservationErrorCanRecoverToKnownExit() {
        let script = ChildWaitScript()
        script.observation = .failed(EINTR)
        script.afterPause = { script.foundation = 0 }
        #expect(waitForEnd(of: Process(), limit: 2, operations: script.operations) == .ended(status: 0))
        #expect(script.notes.count == 1)
    }

    @Test func testLiveTimeoutEscalatesAndRemainsAFault() throws {
        let script = ChildWaitScript()
        script.observation = .running
        script.afterPause = { if script.signals.contains(SIGKILL) { script.foundation = SIGKILL } }
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == 1)
        #expect(faults.first?.contains("did not end within 7 s") == true)
        #expect(script.signals == [SIGTERM, SIGKILL])
        #expect(script.time == 7.25)
    }

    @Test func testStillLiveAfterKillHasASecondBoundedFault() throws {
        let script = ChildWaitScript()
        script.observation = .running
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == 2)
        #expect(faults.last?.contains("still running 5 s") == true)
        #expect(script.signals == [SIGTERM, SIGKILL])
        #expect(script.time == 12)
    }

    @Test func testEndAtEscalationDoesNotSignalDeadPID() throws {
        let script = ChildWaitScript()
        script.observation = .running
        var observationsAtDeadline = 0
        script.beforeObserve = {
            if script.time >= 7 {
                observationsAtDeadline += 1
                if observationsAtDeadline == 2 { script.observation = .ended(collected: true) }
            }
        }
        let agent = try script.agent()
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.count == 1)
        #expect(faults.first?.contains("exit status was lost") == true)
        #expect(script.signals == [SIGTERM])
    }

    @Test func testEstablishedEndCannotBecomeLiveOnShortLimitOrError() {
        let script = ChildWaitScript()
        #expect(waitForEnd(of: Process(), limit: 0, operations: script.operations) == .ended(status: 0))
        script.observation = .failed(EIO)
        #expect(waitForEnd(of: Process(), limit: 0, operations: script.operations, knownEnded: true) == .ended(status: nil))
        script.observation = .running
        #expect(waitForEnd(of: Process(), limit: 0, operations: script.operations, knownEnded: true) == .ended(status: nil))
        #expect(script.signals.isEmpty)
    }
}
