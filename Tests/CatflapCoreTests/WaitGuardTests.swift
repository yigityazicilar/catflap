@testable import CatflapCore
import Testing

/// The tests' default wait must outlast the longest path a send may legitimately take before
/// its row settles. Otherwise a slow runner fails a test the product would pass: a refused
/// text on macOS had not settled when the old 30 s guard, equal to the dial limit alone, ran out.
struct WaitGuardTests {
    @Test func testTheWaitGuardOutlastsTheLongestSend() {
        let limits = TransferLimits()
        // Opening the link: one overall dial deadline, then the two handshake reads. Then the
        // waits for the accept and for the acknowledgement.
        let longest = limits.dial + PeerOpen.handshakeTimeout * 2 + limits.idle * 2
        #expect(testWaitGuard > longest, "the wait guard is \(testWaitGuard), a send may take \(longest)")
    }
}
