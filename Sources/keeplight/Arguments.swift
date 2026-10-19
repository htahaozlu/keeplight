/// Invalid invocation; reported with the command's usage and exit status 2.
struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A command's arguments split into positionals, declared `--flag`s and `--option value` pairs.
/// Options also accept `--option=value`; everything after `--` is positional.
struct Arguments {
    private(set) var positionals: [String] = []
    private var flags: Set<String> = []
    private var options: [String: String] = [:]

    init(_ args: [String], flags knownFlags: Set<String> = [], options knownOptions: Set<String> = []) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            if arg == "--" {
                positionals += rest
                break
            }
            // Negative numbers stay positional so range checks can report them.
            guard arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil else {
                positionals.append(arg)
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0], inline = parts.count > 1 ? parts[1] : nil
            if knownFlags.contains(name), inline == nil {
                flags.insert(name)
            } else if knownOptions.contains(name) {
                guard let value = inline ?? rest.popFirst() else { throw UsageError("\(name) requires a value") }
                options[name] = value
            } else {
                throw UsageError("unknown option '\(arg)'")
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func value(_ option: String) -> String? { options[option] }

    func required(_ index: Int, _ name: String) throws -> String {
        guard index < positionals.count else { throw UsageError("missing <\(name)>") }
        return positionals[index]
    }

    func optional(_ index: Int) -> String? {
        index < positionals.count ? positionals[index] : nil
    }

    func noMore(than count: Int) throws {
        if positionals.count > count { throw UsageError("unexpected argument '\(positionals[count])'") }
    }
}
