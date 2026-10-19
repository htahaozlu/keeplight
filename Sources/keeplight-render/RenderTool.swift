#if DEBUG
import AppKit
import DisplayCore
@testable import KeeplightUI

/// `keeplight-render --out DIR --resources DIR [--only TEXT]`: renders every surface offscreen to
/// PNG at 2×, in light and dark, and writes `index.md` plus `audit.json` (accessibility tree and
/// OCR per image). Exit 0 only when no fake refused a call, no window became visible and the
/// temporary state directory is still empty.
@MainActor
enum RenderTool {
    static func run(arguments: [String]) -> Int32 {
        var out: URL?
        var resources: URL?
        var only: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--out": out = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--resources": resources = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--only": only = iterator.next()
            default:
                FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
                return 2
            }
        }
        guard let out, let resources else {
            FileHandle.standardError.write(Data("usage: keeplight-render --out DIR --resources DIR [--only TEXT]\n".utf8))
            return 2
        }

        let app = NSApplication.shared
        // No Dock icon, no menu bar, never activates.
        app.setActivationPolicy(.prohibited)
        guard let bundle = Bundle(url: resources) else { return fail("no resources at \(resources.path)") }
        _ = bundle
        // The app's icon, as the bundled app has it (first run shows it).
        if let icon = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns")) {
            app.applicationIconImage = icon
        }

        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var results: [Result] = []
        for scenario in Scenarios.all() where only.map({ scenario.name.contains($0) }) ?? true {
            for look in scenario.looks {
                let capture = scenario.render(look)
                let file = "\(scenario.name)--\(look.rawValue).png"
                do {
                    try Renderer.png(capture.image).write(to: out.appendingPathComponent(file))
                } catch {
                    return fail("writing \(file): \(error)")
                }
                let audit = Audit.run(capture)
                results.append(Result(scenario: scenario, look: look, file: file, capture: capture, audit: audit))
                print("rendered \(file)  \(Int(capture.image.pixelsWide))×\(Int(capture.image.pixelsHigh)) px")
            }
        }
        Report.write(results, to: out)

        // Safety gates.
        var failures: [String] = []

        // Panel outline: one boundary at every corner and edge, where `PanelShape` puts it.
        var corners: [String: CornerAudit] = [:]
        for result in results where result.scenario.name.hasPrefix("panel-") {
            let audit = CornerAudit.run(result.capture)
            corners[result.file] = audit
            failures += audit.failures.map { "\(result.file): outline \($0)" }
        }
        let cornerEncoder = JSONEncoder()
        cornerEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? cornerEncoder.encode(corners).write(to: out.appendingPathComponent("corners.json"))

        // Visual gates: 24 × 24 targets, 4.5:1 text.
        for result in results {
            for target in result.audit.smallTargets {
                failures.append("\(result.file): target \"\(target.name)\" is \(fmt(target.w)) × \(fmt(target.h)) pt, under 24 × 24")
            }
            guard result.scenario.checksContrast else { continue }
            for line in result.audit.lowContrast {
                failures.append("\(result.file): text \"\(line.text)\" has contrast \(fmt(line.contrast ?? 0)):1, under 4.5:1")
            }
        }
        let refusals = RefusalLog.shared.all
        if !refusals.isEmpty { failures.append("fakes refused \(refusals.count) call(s): \(refusals.joined(separator: "; "))") }
        let visible = Renderer.visibleWindows
        if !visible.isEmpty { failures.append("\(visible.count) window(s) became visible") }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: Models.directory.path)) ?? []
        if !leftovers.isEmpty { failures.append("state directory not empty: \(leftovers)") }
        try? FileManager.default.removeItem(at: Models.directory)
        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write(Data("keeplight-render: FAIL \(failure)\n".utf8)) }
            return 1
        }
        let targets = results.reduce(0) { $0 + $1.audit.targets.count }
        let lines = results.filter(\.scenario.checksContrast).reduce(0) { $0 + $1.audit.ocr.count }
        print("keeplight-render: \(results.count) images in \(out.path); 0 refused calls, 0 visible windows; "
            + "\(targets) targets all >= 24 x 24 pt; \(lines) text lines all >= 4.5:1; "
            + "\(corners.count) panel outlines with one boundary at every corner and edge")
        return 0
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("keeplight-render: \(message)\n".utf8))
        return 1
    }

    struct Result {
        let scenario: Scenario
        let look: Look
        let file: String
        let capture: Capture
        let audit: Audit
    }
}
#endif
