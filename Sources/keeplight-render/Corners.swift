#if DEBUG
import AppKit
@testable import KeeplightUI

/// Pixel check of a panel capture's outline against `PanelShape`: one boundary at every corner
/// and edge, where the shape puts it. Walking from outside the panel inwards, the pixels must go
/// backdrop → at most a few edge pixels (anti-aliasing and the 0.5 pt hairline) → surface, and
/// never back to backdrop (a gap) or through a second band (a second frame). At the corners the
/// boundary must sit where a circle of `Metrics.panelRadius` crosses the diagonal.
struct CornerAudit: Encodable {
    struct Probe: Encodable {
        var name: String
        /// Pixels walked from the outside before the first non-backdrop pixel.
        var boundary: Int
        var expected: Double
        /// Non-backdrop, non-surface pixels between the two.
        var edgePixels: Int
        var ok: Bool
        var problem: String?
    }

    var radius: Double
    var probes: [Probe] = []
    var failures: [String] { probes.filter { !$0.ok }.map { "\($0.name): \($0.problem ?? "?")" } }

    /// `capture` must be a `.panel` capture (16 pt margin of backdrop around the content).
    static func run(_ capture: Capture) -> CornerAudit {
        let rep = capture.image
        let scale = Double(rep.pixelsWide) / Double(rep.size.width)
        let radius = Double(Metrics.panelRadius) * scale
        var audit = CornerAudit(radius: Double(Metrics.panelRadius))
        let m = Int((Double(capture.margin) * scale).rounded())
        let w = Int((Double(capture.contentSize.width) * scale).rounded())
        let h = Int((Double(capture.contentSize.height) * scale).rounded())
        let backdrop = pixel(rep, 2, 2)
        // The left gutter, halfway down: surface only (the tiles start `Metrics.inset` = 6 pt in).
        let surface = pixel(rep, m + Int(Metrics.inset / 2 * scale), m + h / 2)

        // Corners: walk the diagonal from the content rect's corner pixel inwards.
        let diagonal = radius * (1 - 1 / 2.0.squareRoot())
        let corners: [(String, Int, Int, Int, Int)] = [
            ("top-left", m, m, 1, 1), ("top-right", m + w - 1, m, -1, 1),
            ("bottom-left", m, m + h - 1, 1, -1), ("bottom-right", m + w - 1, m + h - 1, -1, -1),
        ]
        for (name, x0, y0, dx, dy) in corners {
            // Far enough to pass the boundary, short of the tile's corner (6 pt in, concentric).
            let steps = Int(diagonal) + 3 + 8
            let points = (0..<steps).map { (x0 + $0 * dx - dx * 3, y0 + $0 * dy - dy * 3) }
            audit.probes.append(walk(rep, name: name, points: points, offset: 3, expected: diagonal,
                                     backdrop: backdrop, surface: surface, tolerance: 1.5))
        }
        // Edges: from 3 px outside to 8 px inside, at the middle of each side.
        let edges: [(String, [(Int, Int)])] = [
            ("top edge", (0..<12).map { (m + w / 2, m - 3 + $0) }),
            ("bottom edge", (0..<12).map { (m + w / 2, m + h + 2 - $0) }),
            ("left edge", (0..<12).map { (m - 3 + $0, m + h / 2) }),
            ("right edge", (0..<12).map { (m + w + 2 - $0, m + h / 2) }),
        ]
        for (name, points) in edges {
            audit.probes.append(walk(rep, name: name, points: points, offset: 3, expected: 0,
                                     backdrop: backdrop, surface: surface, tolerance: 0.5))
        }
        return audit
    }

    private static func walk(_ rep: NSBitmapImageRep, name: String, points: [(Int, Int)], offset: Int,
                             expected: Double, backdrop: [Double], surface: [Double], tolerance: Double) -> Probe {
        enum Kind { case backdrop, surface, edge }
        let kinds: [Kind] = points.map { x, y in
            let p = pixel(rep, x, y)
            if close(p, backdrop) { return .backdrop }
            if close(p, surface) { return .surface }
            return .edge
        }
        guard let first = kinds.firstIndex(where: { $0 != .backdrop }) else {
            return Probe(name: name, boundary: -1, expected: expected, edgePixels: 0, ok: false, problem: "no surface found")
        }
        let boundary = first - offset
        var problem: String?
        let rest = kinds[first...]
        if rest.contains(.backdrop) { problem = "backdrop shows again inside the outline (a gap)" }
        let surfaceStart = rest.firstIndex(of: .surface)
        let edgePixels = (surfaceStart ?? kinds.endIndex) - first
        if surfaceStart == nil { problem = problem ?? "never reaches the surface color" }
        if let start = surfaceStart, kinds[start...].contains(.edge) {
            problem = problem ?? "a second band after the surface began (a second frame)"
        }
        if edgePixels > 4 { problem = problem ?? "\(edgePixels) edge pixels (expected ≤ 4)" }
        if abs(Double(boundary) - expected) > tolerance + 1 {
            problem = problem ?? "boundary at \(boundary) px, the shape puts it at \(String(format: "%.1f", expected)) px"
        }
        return Probe(name: name, boundary: boundary, expected: expected, edgePixels: edgePixels, ok: problem == nil,
                     problem: problem)
    }

    /// RGBA 0…255, `y` from the top.
    private static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Double] {
        let cx = min(max(x, 0), rep.pixelsWide - 1), cy = min(max(y, 0), rep.pixelsHigh - 1)
        guard let color = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { $0 * 255 }
    }

    private static func close(_ a: [Double], _ b: [Double]) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= 3 }
    }
}
#endif
