import ArgumentParser

struct History: ParsableCommand {
    @OptionGroup var options: ClientOptions
    @Option(name: .long) var search: String?
    func run() throws { try options.call("history", arguments: search.map { ["search": $0] } ?? [:]) }
}
