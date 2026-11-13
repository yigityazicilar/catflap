import ArgumentParser
import CatflapCore

struct Clip: ParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.unavailable() }
}
