import ArgumentParser
import CTailcat

@main
struct Catflap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catflap",
        abstract: "Catflap package skeleton; transfers and desktop integration are not available yet.",
        subcommands: [Version.self]
    )
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the build version and loaded tailcat ABI.")

    mutating func run() {
        print("Catflap 0.1.0-dev")
        print("tailcat-abi \(tc_abi_version())")
    }
}
