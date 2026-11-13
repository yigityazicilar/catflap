import ArgumentParser
import CatflapCore
import Foundation

/// Removes a paired device. The agent closes its server, which ends every open connection,
/// and starts a new one with the remaining devices' keys, or none when no device is left.
struct Unpair: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a paired device and cut it off at once.")
    @OptionGroup var options: ClientOptions
    @Argument(help: "Device id, or name when only one device has it.") var device: String
    func run() throws {
        let result = try PairClient(options).send("unpair", ["device": device], as: UnpairResult.self)
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            print("Removed \(result.name).")
        }
    }
}
