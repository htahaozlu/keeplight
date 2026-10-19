import DisplayCore
import Foundation

enum CLI {
    static var version: String { Keeplight.version }

    static func run(_ argv: [String]) -> Int32 {
        guard let first = argv.first else {
            Output.error(globalHelp)
            return 2
        }
        switch first {
        case "help", "--help", "-h":
            guard argv.count > 1 else {
                print(globalHelp)
                return 0
            }
            guard let command = Command(rawValue: argv[1]) else { return unknown(argv[1]) }
            print(command.help)
            return 0
        case "--version":
            print("keeplight \(version)")
            return 0
        default:
            break
        }
        guard let command = Command(rawValue: first) else { return unknown(first) }

        let rest = Array(argv.dropFirst())
        if rest.prefix(while: { $0 != "--" }).contains(where: { $0 == "-h" || $0 == "--help" }) {
            print(command.help)
            return 0
        }
        do {
            try command.run(Arguments(rest, flags: command.flags, options: command.options))
            return 0
        } catch let error as UsageError {
            Output.error("keeplight: error: \(error.message)")
            Output.error(command.usageText)
            return 2
        } catch {
            Output.error("keeplight: error: \(error)")
            return 1
        }
    }

    private static func unknown(_ name: String) -> Int32 {
        Output.error("keeplight: error: unknown command '\(name)'")
        Output.error("run 'keeplight help' for the list of commands")
        return 2
    }

    static var globalHelp: String {
        let width = Command.allCases.map(\.rawValue.count).max() ?? 0
        let rows = Command.allCases.map {
            "  " + $0.rawValue.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.summary
        }
        return """
            keeplight \(version) - Keeplight command-line tool

            usage: keeplight <command> [arguments]

            commands:
            \(rows.joined(separator: "\n"))

            <display> is a list index (0), a display ID (id:2 or 2), main, builtin,
            or a case-insensitive name substring.

            Changes made here apply immediately (no Keep/Revert prompt) and are recorded
            in the journal shared with the Keeplight app.

            run 'keeplight help <command>' or 'keeplight <command> --help' for details
            """
    }
}

enum Command: String, CaseIterable {
    case list, info, modes, mode, main, mirror, unmirror, enable, disable, brightness, ddc, edid
    case doctor, journal, rescue, interfaces

    var usage: [String] {
        switch self {
        case .list: ["keeplight list [--json]"]
        case .info: ["keeplight info <display> [--json]"]
        case .modes: ["keeplight modes <display> [--all] [--json]"]
        case .mode: ["keeplight mode <display> <WxH[@Hz]> [hidpi|lodpi]",
                     "keeplight mode <display> --number <N> [--force]"]
        case .main: ["keeplight main <display>"]
        case .mirror: ["keeplight mirror <target> <source>"]
        case .unmirror: ["keeplight unmirror <target>"]
        case .enable: ["keeplight enable <display>"]
        case .disable: ["keeplight disable <display>"]
        case .brightness: ["keeplight brightness <display> [<0-100>] [--backend apple|ddc]"]
        case .ddc: ["keeplight ddc <display> get <vcp>", "keeplight ddc <display> set <vcp> <value>"]
        case .edid: ["keeplight edid <display> [--raw | --json]"]
        case .doctor: ["keeplight doctor <display> [--markdown | --json]"]
        case .journal: ["keeplight journal [--since <N>s|m|h|d] [--json]"]
        case .rescue: ["keeplight rescue [--dry-run] [--json]"]
        case .interfaces: ["keeplight interfaces [--json]"]
        }
    }

    var summary: String {
        switch self {
        case .list: "List online displays"
        case .info: "Show display details, EDID summary, brightness backend, DDC match"
        case .modes: "List display modes"
        case .mode: "Set the display mode"
        case .main: "Make a display the main display"
        case .mirror: "Mirror <source> onto <target>"
        case .unmirror: "Stop mirroring on <target>"
        case .enable: "Reconnect a software-disconnected display"
        case .disable: "Software-disconnect a display"
        case .brightness: "Get or set brightness in percent"
        case .ddc: "Read or write a DDC/CI VCP feature"
        case .edid: "Show the display's EDID"
        case .doctor: "Diagnose brightness control for a display"
        case .journal: "Show the change journal"
        case .rescue: "Get back to a working display setup"
        case .interfaces: "Show the private macOS symbols Keeplight uses and their status"
        }
    }

    private var details: [String] {
        switch self {
        case .modes:
            ["Default: one row per distinct usable mode, HiDPI first, then by width and refresh",
             "rate (descending); '*' marks the current mode; TAG is CRISP, SCALED, NATIVE or SOFT",
             "against the panel's native pixels. --all lists every CGS mode in order, including",
             "modes without the valid flag (0x1)."]
        case .mode:
            ["Without hidpi/lodpi a non-HiDPI mode is preferred; the highest matching refresh",
             "rate wins. --number takes a mode number from 'keeplight modes <display> --all';",
             "modes without the valid flag are refused unless --force is given."]
        case .enable:
            ["A disconnected display is no longer listed; pass its display ID (N or id:N), as",
             "printed by 'keeplight disable', or its name as remembered by Keeplight. Numbers are",
             "display IDs here, not list indices."]
        case .disable:
            ["Refuses to disconnect the last active physical display (built-in or",
             "framebuffer-driven). The change lasts until logout; Keeplight remembers the display",
             "so 'keeplight rescue' and the app can reconnect it."]
        case .brightness:
            ["Without a value prints the current brightness. The backend defaults to the best",
             "available one (apple, then ddc)."]
        case .ddc:
            ["<vcp> is a name (brightness, contrast, volume, mute, input, power, red, green,",
             "blue) or a code (0x10, 16). <value> is decimal or 0x-prefixed hex."]
        case .edid:
            ["--raw prints a hex dump of every EDID byte, extension blocks included."]
        case .doctor:
            ["Checks connection, Mac, Apple brightness, DDC channel, DDC reply and EDID, grading",
             "each step OBSERVED, NO REPLY, NOT AVAILABLE or NOT TESTED, then explains the result",
             "in one sentence. Read-only. --markdown prints a report for a GitHub issue with the",
             "serial redacted to its last 3 characters."]
        case .journal:
            ["Changes made by the app and this tool, oldest first. --since limits the output to",
             "a recent window, e.g. 30m, 1h or 2d."]
        case .rescue:
            ["Reverts a pending change, reconnects displays Keeplight disconnected, stops mirrors",
             "Keeplight created, then restores the last kept setup for this set of displays, or",
             "makes the built-in display main and gives each display its default mode.",
             "--dry-run prints the plan without changing anything. Over SSH, run it inside the",
             "GUI session: launchctl asuser $(id -u) keeplight rescue"]
        case .interfaces:
            ["Undocumented functions are resolved at runtime; when one is missing on this",
             "macOS, the feature that needs it turns off instead of crashing."]
        default: []
        }
    }

    var flags: Set<String> {
        switch self {
        case .list, .info, .interfaces, .journal: ["--json"]
        case .modes: ["--all", "--json"]
        case .edid: ["--raw", "--json"]
        case .mode: ["--force"]
        case .doctor: ["--markdown", "--json"]
        case .rescue: ["--dry-run", "--json"]
        default: []
        }
    }

    var options: Set<String> {
        switch self {
        case .mode: ["--number"]
        case .brightness: ["--backend"]
        case .journal: ["--since"]
        default: []
        }
    }

    var usageText: String {
        usage.enumerated().map { ($0.offset == 0 ? "usage: " : "       ") + $0.element }.joined(separator: "\n")
    }

    var help: String {
        ([usageText, "", summary + "."] + (details.isEmpty ? [] : [""] + details)).joined(separator: "\n")
    }

    func run(_ args: Arguments) throws {
        switch self {
        case .list: try Commands.list(args)
        case .info: try Commands.info(args)
        case .modes: try Commands.modes(args)
        case .mode: try Commands.mode(args)
        case .main: try Commands.main(args)
        case .mirror: try Commands.mirror(args)
        case .unmirror: try Commands.unmirror(args)
        case .enable: try Commands.enable(args)
        case .disable: try Commands.disable(args)
        case .brightness: try Commands.brightness(args)
        case .ddc: try Commands.ddc(args)
        case .edid: try Commands.edid(args)
        case .doctor: try Commands.doctor(args)
        case .journal: try Commands.journal(args)
        case .rescue: try Commands.rescue(args)
        case .interfaces: try Commands.interfaces(args)
        }
    }
}
