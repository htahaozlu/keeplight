#if DEBUG
import AppKit
import Darwin

/// Debug only (`KEEPLIGHT_DEBUG_PANEL=1` plus `KEEPLIGHT_DEBUG_SHOTS=<directory>`): writes PNGs of
/// this app's own windows and quits. Nothing is captured outside the app, and it needs no
/// screen-recording permission. Used to check layout without touching the displays.
@MainActor
enum DebugCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func scheduleIfRequested(flags: LaunchFlags) {
        let env = ProcessInfo.processInfo.environment
        guard flags.debug, let path = env["KEEPLIGHT_DEBUG_SHOTS"], !path.isEmpty else { return }
        let name = env["KEEPLIGHT_DEBUG_NAME"] ?? "shot"
        let delay = Double(env["KEEPLIGHT_DEBUG_DELAY"] ?? "") ?? 3
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(into: directory, name: name)
            NSApp.terminate(nil)
        }
    }

    private static func capture(into directory: URL, name: String) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        for window in NSApp.windows where window.isVisible && window.frame.width > 60 && window.alphaValue > 0.01 {
            let kind: String
            switch window {
            case is KeeplightPanel: kind = "panel"
            case is InstrumentPanel: kind = window.ignoresMouseEvents ? "identify" : "ring"
            default: kind = "window"
            }
            // boundsIgnoreFraming | bestResolution
            guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            let number = window.windowNumber
            try? data.write(to: directory.appendingPathComponent("\(name)-\(kind)-\(number).png"))
        }
        writeGlyphs(into: directory, name: name)
    }

    /// The status icon at 12× on white.
    private static func writeGlyphs(into directory: URL, name: String) {
        let scale: CGFloat = 12
        let icon = StatusItemController.icon
        let side = 18 * scale
        let sheet = NSImage(size: NSSize(width: side + 24, height: side + 24), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r)
                NSColor.black.set()
                r.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: 12, y: 12, width: side, height: side))
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name)-glyph.png"))
    }
}
#endif
