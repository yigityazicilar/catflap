import ArgumentParser
import CatflapCore

struct Send: ParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.unavailable() }
}
