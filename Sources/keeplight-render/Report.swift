#if DEBUG
import AppKit
@testable import KeeplightUI

/// `index.md` (what each PNG shows) and `audit.json` (per image: size, accessibility elements,
/// OCR lines).
@MainActor
enum Report {
    private struct Entry: Encodable {
        var file: String
        var surface: String
        var scenario: String
        var state: String
        var look: String
        var widthPt: Double
        var heightPt: Double
        var pixels: [Int]
        var audit: Audit
    }

    static func write(_ results: [RenderTool.Result], to out: URL) {
        let entries = results.map { r in
            Entry(file: r.file, surface: r.scenario.surface, scenario: r.scenario.name, state: r.scenario.state,
                  look: r.look.rawValue, widthPt: Double(r.capture.contentSize.width),
                  heightPt: Double(r.capture.contentSize.height),
                  pixels: [r.capture.image.pixelsWide, r.capture.image.pixelsHigh], audit: r.audit)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(entries).write(to: out.appendingPathComponent("audit.json"))

        var md = """
        # Keeplight renders (offscreen, 2×)

        Rendered by `keeplight-render` (debug-only tool, never bundled) from the real SwiftUI/AppKit
        views on fake services: synthetic displays, no hardware calls, no windows on screen, in-memory
        preferences. \(results.count) PNGs, each in light and dark.

        Notes on fidelity:
        - Panels are drawn in the app's own container (`PanelMaterial.container`) in its **Reduce
          Transparency** form (opaque fill + hairline). The `.menu` vibrancy and the window shadow are
          drawn by the window server and cannot be captured offscreen; `corners.json` checks
          the four corners and edges of every panel image against `PanelShape`.
        - Overlays (Revert Ring, Identify, OSD) sit on a plain backdrop with a 16 pt margin; the
          instrument plate is always dark by design, so light and dark should match.
        - The status glyph strip shows the template tinted as the menu bar does, at 18 pt in a 24 pt
          bar, plus a 5× vector drawing; the signal dot is drawn where `setPendingDot` places it in
          unflipped coordinates.
        - Settings tabs are the window's content view at the controller's content size (no title bar).
        - Sizes are points; PNG pixels are 2×. `audit.json` has the accessibility tree and OCR per image.


        """
        let surfaces = Array(NSOrderedSet(array: results.map(\.scenario.surface))) as? [String] ?? []
        for surface in surfaces {
            md += "## \(surface)\n\n| Scenario | State | Light | Dark | Size (pt) | OCR words |\n|---|---|---|---|---|---|\n"
            let rows = results.filter { $0.scenario.surface == surface }
            let names = Array(NSOrderedSet(array: rows.map(\.scenario.name))) as? [String] ?? []
            for name in names {
                let pair = rows.filter { $0.scenario.name == name }
                guard let first = pair.first else { continue }
                let light = pair.first { !$0.look.isDark }?.file ?? "—"
                let dark = pair.first { $0.look.isDark }?.file ?? "—"
                let size = "\(Int(first.capture.contentSize.width)) × \(Int(first.capture.contentSize.height))"
                md += "| `\(name)` | \(first.scenario.state) | [\(light)](\(light)) | [\(dark)](\(dark)) | \(size) | \(first.audit.ocrWords) |\n"
            }
            md += "\n"
        }
        try? md.write(to: out.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }
}
#endif
