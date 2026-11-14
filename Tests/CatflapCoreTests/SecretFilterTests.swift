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
    /// A copy up to the 4 MiB text limit that nearly matches a pattern is checked in linear
    /// time. As a regex the JWT check took 22 s on 128 KiB of "eyJ-" and hours on 4 MiB,
    /// holding the clipboard actor the whole time.
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
            for size in [128 * 1024, ClipboardHistory.textLimit] {
                let (bytes, took) = try await filterOffPool { () -> (Int, Duration) in
                    let text = make(size)
                    let start = ContinuousClock.now
                    _ = SecretFilter.rejects(text)
                    return (text.utf8.count, start.duration(to: .now))
                }
                let limit: Duration = size == ClipboardHistory.textLimit ? .seconds(20) : .seconds(3)
                #expect(took < limit, "\(label), \(bytes) bytes: \(took)")
                // A family already slow at 128 KiB would take hours at 4 MiB.
                if took >= limit { break }
            }
        }
    }
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
