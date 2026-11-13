import ArgumentParser
import CatflapCore

struct Pair: ParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.unavailable() }
}
