import DisplayCore
import Foundation

extension Commands {
    static func doctor(_ args: Arguments) throws {
        try args.noMore(than: 1)
        if args.has("--markdown"), args.has("--json") { throw UsageError("--markdown and --json are mutually exclusive") }
        let d = try resolve(args.required(0, "display"))
        let report = Diagnostics.diagnose(d)
        if args.has("--json") { return try Output.json(report) }
        if args.has("--markdown") { return print(report.markdownReport()) }
        print(d.tag)
        Output.table(["STEP", "RESULT", "DETAIL", "MS"], report.steps.map { step in
            [step.name, step.grade.label, step.detail, step.ms.map(String.init) ?? "-"]
        }, right: [3])
        print("")
        print(report.verdict)
    }

    static func journal(_ args: Arguments) throws {
        try args.noMore(than: 0)
        let since = try args.value("--since").map { raw -> Date in
            guard let seconds = Format.duration(raw) else {
                throw UsageError("--since expects a duration like 30m, 1h or 2d, got '\(raw)'")
            }
            return Date().addingTimeInterval(-seconds)
        }
        let entries = Journal.standard.entries(since: since)
        if args.has("--json") { return try Output.json(entries) }
        guard !entries.isEmpty else {
            print(since == nil ? "The journal is empty." : "No changes in that window.")
            return
        }
        Output.table(["TIME", "VIA", "DISPLAY", "KIND", "CHANGE", "RESULT", "REASON"], entries.map { e in
            [Format.localTime(e.t), e.source.rawValue, e.display?.name ?? "-", e.kind.rawValue,
             Format.change(e), e.result.rawValue, e.reason ?? "-"]
        })
    }

    static func rescue(_ args: Arguments) throws {
        try args.noMore(than: 0)
        let rescue = Rescue.standard()
        let dryRun = args.has("--dry-run")
        let outcomes = rescue.run(dryRun: dryRun)
        if args.has("--json") {
            try Output.json(outcomes.map { RescueRecord(step: $0.step.description, error: $0.error, dryRun: dryRun) })
            if !dryRun, outcomes.contains(where: { $0.error != nil }) {
                throw DisplayError.refused("some rescue steps failed")
            }
            return
        }
        guard !outcomes.isEmpty else {
            print("Nothing to rescue: no pending change, no displays Keeplight disconnected or mirrored, "
                  + "and every display is already in its rescue setup.")
            return
        }
        print(dryRun ? "Rescue plan (dry run, nothing was changed):" : "Rescue:")
        for (i, outcome) in outcomes.enumerated() {
            let status = dryRun ? "" : (outcome.error.map { " — failed: \($0)" } ?? " — done")
            print("  \(i + 1). \(outcome.step.description)\(status)")
        }
        if !dryRun, outcomes.contains(where: { $0.error != nil }) {
            throw DisplayError.refused("some rescue steps failed")
        }
    }

    static func interfaces(_ args: Arguments) throws {
        try args.noMore(than: 0)
        let all = PrivateInterfaces.all
        if args.has("--json") { return try Output.json(all) }
        Output.table(["SYMBOL", "FRAMEWORK", "USED FOR", "STATUS"], all.map { i in
            [i.symbol, i.framework, i.purpose, i.isResolved ? "Resolved" : "Missing — feature off"]
        })
        print("")
        print("\(all.filter(\.isResolved).count) of \(all.count) resolved")
    }
}

struct RescueRecord: Encodable {
    let step: String
    let error: String?
    let dryRun: Bool
}
