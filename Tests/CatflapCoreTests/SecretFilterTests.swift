@testable import CatflapCore
import Foundation
import Testing

@Suite(.serialized) struct SecretFilterTests {
    @Test func testFixtureSecretsRejectedAndOrdinaryTextAccepted() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (name, expected) in [("secrets", true), ("not-secrets", false)] {
            let lines = try String(contentsOf: fixtures.appendingPathComponent(name + ".txt"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            // Provider token shapes are not in secrets.txt (see below), so it holds fewer lines;
            // with them the secret cases number more than forty.
            #expect(lines.count >= (expected ? 20 : 40))
            for (line, text) in lines.enumerated() {
                // Only the fixture location is reported on failure, never its content.
                let rejected = SecretFilter.rejects(String(text))
                #expect(rejected == expected, "Fixture \(name), line \(line + 1)")
            }
            if name == "secrets" {
                let pairing = try #require(lines.first(where: { $0.hasPrefix("catflap-pair-1.") }))
                let valid = PairingCode(String(pairing)) != nil
                #expect(valid)
            }
        }
    }
    /// Shapes that are never written to a file. A provider's token, even a made-up one, raises
    /// a secret-scanning alert in a public repository (a Google-shaped fixture line did) and a
    /// live-looking Stripe key is refused by GitHub outright; no file may hold a tailcat
    /// address. So these are built here from random characters each run.
    @Test func testShapesBuiltAtRunTimeAreRejected() {
        func random(_ count: Int, from alphabet: String) -> String {
            String((0..<count).map { _ in alphabet.randomElement()! })
        }
        let upperDigits = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let alphanumerics = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let base64url = alphanumerics + "-_"
        let digits = "0123456789"
        // Prefixes are split so that no source line holds a whole token shape either.
        var shapes: [(String, String)] = []
        for kind in ["p", "o", "u", "s", "r"] { shapes.append(("GitHub gh\(kind)_ token", "gh" + kind + "_" + random(36, from: alphanumerics))) }
        shapes.append(("GitHub fine-grained token", "github" + "_pat_" + random(82, from: alphanumerics + "_")))
        shapes.append(("OpenAI key", "sk" + "-" + random(48, from: alphanumerics)))
        shapes.append(("OpenAI project key", "sk" + "-proj-" + random(100, from: base64url)))
        shapes.append(("Stripe secret key", "sk_" + "live_" + random(24, from: alphanumerics)))
        shapes.append(("Stripe restricted key", "rk_" + "live_" + random(24, from: alphanumerics)))
        for kind in ["b", "p", "a", "r", "s"] {
            shapes.append(("Slack xox\(kind) token", "xox" + kind + "-" + random(12, from: digits) + "-" + random(13, from: digits) + "-" + random(24, from: alphanumerics)))
        }
        shapes.append(("Google API key", "AI" + "za" + random(35, from: base64url)))
        shapes.append(("AWS access key id", "AK" + "IA" + random(16, from: upperDigits)))
        shapes.append(("AWS temporary key id", "AS" + "IA" + random(16, from: upperDigits)))
        shapes.append(("JWT", "ey" + "JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." + random(40, from: base64url) + "." + random(43, from: base64url)))
        // The shortest tailcat address (about 56 characters) and one carrying relay details.
        for length in [54, 146] {
            let address = "tc" + random(length, from: base64url)
            shapes.append(("tailcat address of \(length + 2) characters", address))
            shapes.append(("tailcat address inside a sentence", "my address is " + address))
        }
        #expect(shapes.count >= 20)
        for (label, text) in shapes {
            // The label is reported on failure, never the generated value.
            #expect(SecretFilter.rejects(text), "\(label)")
        }
    }
    /// Random letters with "_" or "-" in them are a token (base64url that happens to have no
    /// digit), not snake_case or kebab-case: they switch case at random. The same for letters
    /// alone. The draw comes from a fixed seed, so it is the same on every run, and is never
    /// printed.
    @Test func testRandomLettersAndJoinersAreRejected() async throws {
        let counts = try await filterOffPool { () -> [(String, Int)] in
            var generator = SeededGenerator(seed: 0x5EED_CA7F_1A90_0001)
            var counts: [(String, Int)] = []
            for (label, alphabet, length) in [("letters and joiners", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-", 48),
                                              ("letters", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", 40)] {
                let characters = Array(alphabet)
                var accepted = 0
                for _ in 0..<500 {
                    var value = String((0..<length).map { _ in characters.randomElement(using: &generator)! })
                    if label == "letters and joiners" { value += "_-" }
                    if !SecretFilter.rejects(value) { accepted += 1 }
                }
                counts.append((label, accepted))
            }
            return counts
        }
        #expect(counts.count == 2)
        for (label, accepted) in counts {
            #expect(accepted <= 10, "\(label): \(accepted) of 500 random values accepted")
        }
    }
    /// The JWT check is a one-pass scan. On short strings it must find exactly what the regex
    /// it replaced finds, less the regex's closing word boundary. The pieces make every case
    /// likely: starts after a hyphen or an underscore, missing runs, double dots, spaces.
    /// A UUID is an identifier, not a secret (the person's decision, 2026-11-14), so one copied
    /// on its own is kept, in either case. The exemption is for that shape only: 36 random
    /// letters and digits laid out 8-4-4-4-12 are still a token.
    @Test func testBareUUIDsAreKept() async throws {
        let (uuids, lookalikes) = try await filterOffPool { () -> (Int, Int) in
            var kept = 0
            for index in 0..<1000 {
                let value = UUID().uuidString
                if !SecretFilter.rejects(index % 2 == 0 ? value : value.lowercased()) { kept += 1 }
            }
            var generator = SeededGenerator(seed: 0x5EED_CA7F_1A90_0002)
            let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            var accepted = 0
            for _ in 0..<500 {
                let groups = [8, 4, 4, 4, 12].map { length in
                    String((0..<length).map { _ in characters.randomElement(using: &generator)! })
                }
                if !SecretFilter.rejects(groups.joined(separator: "-")) { accepted += 1 }
            }
            return (kept, accepted)
        }
        #expect(uuids == 1000, "\(1000 - uuids) of 1000 UUIDs were treated as secrets")
        #expect(lookalikes <= 10, "\(lookalikes) of 500 random 8-4-4-4-12 tokens were accepted")
    }
    @Test func testJWTScanFindsWhatTheRegexFinds() async throws {
        let (found, different) = try await filterOffPool { () -> (Int, [String]) in
            var generator = SeededGenerator(seed: 0x7E57_0000_0000_0042)
            let pieces = ["eyJ", "eyJ", "eyJ", "a", "Z", "0", "_", "-", "-", ".", ".", ".", " ", "e", "yJ", ":"]
            let regex = try NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
            var found = 0, different: [String] = []
            for _ in 0..<20_000 {
                let text = (0..<Int.random(in: 1...14, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
                let expected = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
                if expected { found += 1 }
                if SecretFilter.containsJWT(text) != expected, different.count < 5 { different.append(text) }
            }
            return (found, different)
        }
        // These are short made-up strings, not secrets, so the first few differences are shown.
        #expect(different.isEmpty, "scan and regex differ on: \(different)")
        #expect(found >= 200, "the draw found \(found) JWT shapes")
    }
    /// The scaling check itself: work that reads from every position to the end, as a pattern
    /// that restarts at every word start does, fails it, and one pass over the input passes.
    @Test func testScalingCheckFailsOnQuadraticWork() async throws {
        let make: @Sendable (Int) -> String = { String(repeating: "a", count: $0) }
        // Factor 64 gives triangular work a ratio of 4080.3 before overhead, leaving
        // headroom above 1024. The product check remains factor 32 with cutoff 256.
        let quadratic = try await measureScaling("quadratic work", small: 256, factor: 64, make: make,
                                               expected: { text in
            let count = text.utf8.count
            return count * (count + 1) / 2
        }, work: quadraticMatches)
        #expect(quadratic.ratio >= 1024, "quadratic self-test margin: \(quadratic)")
        withKnownIssue("quadratic work must fail the scaling check") {
            // Only this assertion is expected to fail, never measurement or checksum checks.
            expectLinearScaling(quadratic)
        } matching: { issue in
            if case .expectationFailed = issue.kind { return true }
            return false
        }
        let linear = try await measureScaling("linear work", small: 64 * 1024, make: make,
                                            expected: { $0.utf8.count }, work: linearMatches)
        expectLinearScaling(linear)
        #expect(linear.ratio <= 64, "linear self-test margin: \(linear)")
    }
    /// A copy that nearly matches a pattern is checked in linear time: 32 times the input
    /// takes about 32 times as long. As a regex the JWT check took 22 s on 128 KiB of "eyJ-"
    /// and hours on 4 MiB, holding the clipboard actor the whole time. The sizes are 4 KiB and
    /// 128 KiB, so that a pattern gone quadratic fails here in a minute or two instead of
    /// running for hours at the 4 MiB text limit.
    @Test func testLongNearMissesFinishQuickly() async throws {
        let families: [(String, @Sendable (Int) -> String)] = [
            ("JWT start after a hyphen", { String(repeating: "eyJ-", count: $0 / 4) }),
            ("JWT starts with no dot", { String(repeating: "eyJ", count: $0 / 3) + "." }),
            ("JWT with one dot", { "eyJa." + String(repeating: "eyJ-", count: $0 / 4) }),
            ("hyphens after tc", { "-tc" + String(repeating: "-", count: $0) }),
            ("hyphens after sk-", { "sk-" + String(repeating: "-", count: $0) }),
            ("hyphens after xoxb-", { "xoxb-" + String(repeating: "-", count: $0) }),
            ("GitHub prefixes ending in an underscore", { String(repeating: "-gh" + "p_" + String(repeating: "a", count: 30) + "_", count: $0 / 36) }),
            ("key header with no PRIVATE", { "-----BEGIN " + String(repeating: "A ", count: $0 / 2) }),
            ("key headers repeated", { String(repeating: "-----BEGIN A ", count: $0 / 13) }),
            ("one letter", { String(repeating: "A", count: $0) })
        ]
        for (label, make) in families {
            try await expectLinearScaling(label, small: 4 * 1024, make: make) { SecretFilter.rejects($0) }
        }
    }
}

/// Read runtime bytes without slices or allocations per comparison. Returning each count
/// to the measured batch keeps its result observable, including in optimized builds.
@inline(never)
private func quadraticMatches(_ text: String) -> Int {
    Array(text.utf8).withUnsafeBufferPointer { bytes in
        var matches = 0
        var start = 0
        while start < bytes.count {
            var index = start
            while index < bytes.count {
                if bytes[index] == bytes[start] { matches += 1 }
                index += 1
            }
            start += 1
        }
        return matches
    }
}

@inline(never)
private func linearMatches(_ text: String) -> Int {
    Array(text.utf8).withUnsafeBufferPointer { bytes in
        var matches = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "a") { matches += 1 }
            index += 1
        }
        return matches
    }
}

/// Best per-call times at two sizes. The product uses factor 32; only the quadratic
/// self-test uses factor 64 to leave room for measurement overhead.
private struct Scaling: CustomStringConvertible, Sendable {
    let label: String
    let smallBytes: Int, largeBytes: Int
    let smallBest: Duration, largeBest: Duration
    var ratio: Double { largeBest / smallBest }
    var description: String {
        let milliseconds = { (time: Duration) in String(format: "%.3f", time / .milliseconds(1)) }
        return "scaling: \(label), \(smallBytes) and \(largeBytes) bytes, best \(milliseconds(smallBest)) "
            + "and \(milliseconds(largeBest)) ms, ratio \(String(format: "%.1f", ratio))"
    }
}

/// The product guard is shared with the self-test, whose expected issue surrounds only
/// this assertion. Measurement errors and margin expectations remain ordinary failures.
private func expectLinearScaling(_ scaling: Scaling, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(scaling.ratio < 256, "\(scaling)", sourceLocation: sourceLocation)
}

@discardableResult
private func expectLinearScaling(_ label: String, small: Int, make: @escaping @Sendable (Int) -> String,
                                 sourceLocation: SourceLocation = #_sourceLocation,
                                 work: @escaping @Sendable (String) -> Bool) async throws -> Scaling {
    let scaling = try await measureScaling(label, small: small, make: make, expected: work, work: work)
    expectLinearScaling(scaling, sourceLocation: sourceLocation)
    return scaling
}

private struct InvalidScalingWork: Error, CustomStringConvertible {
    let label: String
    let bytes: Int
    var description: String { "scaling workload validation failed: \(label), \(bytes) bytes" }
}

/// Interleave small and large batches three times and keep the best per-call times.
/// Batches shorter than 5 ms are doubled to measure work rather than clock resolution;
/// that is a calibration floor, not an absolute success bound. Each call stores its result
/// in a preallocated slot, then every slot is validated after stopping the clock, even for
/// calibration batches. Both sizes have independent expected results. No timed result is
/// discarded, and no assertion or checksum validation is inside the timed loop.
private func measureScaling<Value: Equatable & Sendable>(
    _ label: String, small: Int, factor: Int = 32, make: @escaping @Sendable (Int) -> String,
    expected: @escaping @Sendable (String) -> Value,
    work: @escaping @Sendable (String) -> Value
) async throws -> Scaling {
    try Task.checkCancellation()
    let scaling = try await filterOffPool { () -> Scaling in
        let inputs = [make(small), make(small * factor)]
        let expectedResults = inputs.map(expected)
        var repeats = [1, 1]
        var best: [Duration?] = [nil, nil]
        for _ in 0..<3 {
            for side in 0..<2 {
                while true {
                    var results = Array(repeating: expectedResults[side], count: repeats[side])
                    let start = ContinuousClock.now
                    for index in results.indices { results[index] = work(inputs[side]) }
                    let took = start.duration(to: .now)
                    guard results.allSatisfy({ $0 == expectedResults[side] }) else {
                        throw InvalidScalingWork(label: label, bytes: inputs[side].utf8.count)
                    }
                    if took < .milliseconds(5) {
                        repeats[side] *= 2
                        continue
                    }
                    let each = took / repeats[side]
                    best[side] = min(best[side] ?? each, each)
                    break
                }
            }
        }
        return Scaling(label: label, smallBytes: inputs[0].utf8.count, largeBytes: inputs[1].utf8.count,
                       smallBest: best[0]!, largeBest: best[1]!)
    }
    try Task.checkCancellation()
    print(scaling)
    return scaling
}

/// Runs a filter workload on a thread of its own. A synchronous test holds one of Swift's
/// cooperative threads for as long as it runs, and macOS keeps only as many as there are
/// cores: three of these tests at once took every one on a CI runner, and four unrelated
/// tests timed out waiting for their own async work. The suite is also serialized.
private func filterOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// SplitMix64, so that a statistical test draws the same values on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
