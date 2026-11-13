import ArgumentParser

struct Unpair: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.unavailable() }
}
