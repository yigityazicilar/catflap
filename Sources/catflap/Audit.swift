import ArgumentParser
import CatflapCore

struct Audit: ParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.unavailable() }
}
