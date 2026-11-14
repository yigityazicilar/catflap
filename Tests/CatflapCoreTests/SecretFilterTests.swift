import CatflapCore
import Foundation
import Testing

@Suite struct SecretFilterTests {
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
}
