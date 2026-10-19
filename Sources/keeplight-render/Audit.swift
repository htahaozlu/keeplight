#if DEBUG
import AppKit
import Vision
@testable import KeeplightUI

/// Measurements taken from one capture: the frames of the interactive controls (reported by the
/// views themselves through `hitTarget`, at the size SwiftUI laid them out) and on-device OCR of
/// the PNG with the pixel contrast of every recognized line. Nothing leaves the process.
struct Audit: Encodable {
    struct Target: Encodable {
        var name: String
        /// Points, window coordinates.
        var x: Double, y: Double, w: Double, h: Double
        var enabled: Bool
    }

    struct Line: Encodable {
        var text: String
        var confidence: Double
        var x: Double, y: Double, w: Double, h: Double
        /// Text pixel versus background pixel, WCAG ratio (1...21); nil when the box has no ink.
        var contrast: Double?
        /// Inside a disabled control: exempt from the contrast gate.
        var disabled = false
    }

    var targets: [Target] = []
    var ocr: [Line] = []

    /// Whitespace-separated tokens with at least one letter.
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }.count
    }

    var ocrWords: Int { ocr.reduce(0) { $0 + Self.words($1.text) } }

    /// Smallest allowed hit target, in points, per side.
    static let minTarget = Double(Metrics.minTarget)
    /// WCAG AA for text.
    static let minContrast = 4.5

    /// Controls under 24 pt in either dimension.
    var smallTargets: [Target] { targets.filter { $0.w < Self.minTarget - 0.01 || $0.h < Self.minTarget - 0.01 } }
    /// Recognized lines under 4.5:1.
    var lowContrast: [Line] {
        ocr.filter {
            ($0.contrast ?? .infinity) < Self.minContrast && !$0.disabled
                // A glyph such as `···` is not text; anti-aliasing leaves its dots far below their color.
                && $0.text.contains { $0.isLetter || $0.isNumber }
        }
    }

    @MainActor
    static func run(_ capture: Capture) -> Audit {
        var audit = Audit()
        audit.targets = capture.sink.targets.values
            .map { Target(name: $0.name, x: Double($0.frame.minX), y: Double($0.frame.minY),
                          w: Double($0.frame.width), h: Double($0.frame.height), enabled: $0.enabled) }
            .sorted { ($0.name, $0.w) < ($1.name, $1.w) }
        audit.ocr = recognize(capture)
        let margin = Double(capture.margin)
        let disabled = capture.sink.targets.values.filter { !$0.enabled }.map(\.frame)
        for index in audit.ocr.indices {
            let line = audit.ocr[index]
            let center = CGPoint(x: line.x + line.w / 2 + margin, y: line.y + line.h / 2 + margin)
            audit.ocr[index].disabled = disabled.contains { $0.contains(center) }
        }
        return audit
    }

    private static func recognize(_ capture: Capture) -> [Line] {
        guard let image = capture.image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let width = Double(capture.image.size.width)
        let height = Double(capture.image.size.height)
        let margin = Double(capture.margin)
        let pixels = Pixels(capture.image)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
                              height: box.height * height)
            return Line(text: candidate.string, confidence: Double(candidate.confidence),
                        x: rect.minX - margin, y: rect.minY - margin, w: rect.width, h: rect.height,
                        contrast: pixels.contrast(in: CGRect(x: rect.minX * pixels.scale, y: rect.minY * pixels.scale,
                                                                 width: rect.width * pixels.scale,
                                                                 height: rect.height * pixels.scale)))
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}

/// Read access to a capture's pixels (sRGB, 2×).
private struct Pixels {
    let width: Int, height: Int, scale: Double
    private let data: [UInt8]

    init(_ rep: NSBitmapImageRep) {
        width = rep.pixelsWide
        height = rep.pixelsHigh
        scale = Double(rep.pixelsWide) / Double(rep.size.width)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if let cg = rep.cgImage, let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        data = bytes
    }

    /// WCAG relative luminance of the pixel at (x, y), top-left origin.
    private func luminance(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        func channel(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(data[i]) + 0.7152 * channel(data[i + 1]) + 0.0722 * channel(data[i + 2])
    }

    /// Contrast between the box's background (its most common luminance) and its inkiest pixel
    /// (the one farthest from the background). `rect` is in capture pixels, top-left origin.
    func contrast(in rect: CGRect) -> Double? {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width - 1, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height - 1, Int(rect.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return nil }
        var histogram: [Int: (count: Int, value: Double)] = [:]
        var values: [Double] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let l = luminance(x, y)
                values.append(l)
                let key = Int((l * 255).rounded())
                histogram[key, default: (0, l)].count += 1
            }
        }
        guard let background = histogram.values.max(by: { $0.count < $1.count })?.value,
              let ink = values.max(by: { abs($0 - background) < abs($1 - background) })
        else { return nil }
        let (hi, lo) = (max(background, ink), min(background, ink))
        return (hi + 0.05) / (lo + 0.05)
    }
}
#endif
