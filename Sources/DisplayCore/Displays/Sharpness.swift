import CoreGraphics
import Foundation

/// How a mode maps points to the panel's native pixels.
public enum Sharpness: String, Codable, CaseIterable, Sendable {
    /// HiDPI and exactly 2 × 2 pixels per point at native resolution.
    case crisp
    /// HiDPI drawn at 2× and then resampled to the panel.
    case scaled
    /// One pixel per point at native resolution.
    case native
    /// Not HiDPI and not native: the monitor or GPU stretches it.
    case soft

    /// Chip text: `CRISP`, `SCALED`, `NATIVE`, `SOFT`.
    public var tag: String { rawValue.uppercased() }
}

extension DisplayMode {
    /// Classification against the panel's native pixel size [O§5.2].
    public func sharpness(native: (width: Int, height: Int)) -> Sharpness {
        let atNative = pixelWidth == native.width && pixelHeight == native.height
        if isHiDPI { return atNative ? .crisp : .scaled }
        return atNative ? .native : .soft
    }

    /// `nativeW / pixelWidth` for scaled modes, e.g. 0.75 for 2560×1440 HiDPI on a 4K panel.
    public func scale(native: (width: Int, height: Int)) -> Double {
        pixelWidth > 0 ? Double(native.width) / Double(pixelWidth) : 0
    }
}

extension DisplayManager {
    /// Panel pixels: the EDID preferred timing, else a mode carrying the native flag, else the
    /// largest usable non-HiDPI mode, else the largest usable mode. (HiDPI "more space" modes
    /// have backing stores larger than the panel, so they are the last resort.)
    public static func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let info = info(for: id)
        if let t = EDID.read(for: info)?.preferredTiming, t.horizontalActive > 0, t.verticalActive > 0 {
            return (t.horizontalActive, t.verticalActive)
        }
        return nativePixelSize(fromModes: modes(for: id))
    }

    /// The mode-list part of `nativePixelSize(for:)`.
    public static func nativePixelSize(fromModes modes: [DisplayMode]) -> (width: Int, height: Int)? {
        let usable = modes.filter(\.isUsable)
        let largest = { (candidates: [DisplayMode]) in
            candidates.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        }
        let pick = largest(usable.filter(\.isNativeFlagged)) ?? largest(usable.filter { !$0.isHiDPI })
            ?? largest(usable)
        return pick.map { ($0.pixelWidth, $0.pixelHeight) }
    }

    /// The "Looks like" list [O§5.2]: one mode per logical size at the current refresh rate,
    /// tagged CRISP, SCALED or NATIVE; at most `limit` rows. Always contains `current` and
    /// every CRISP size, then the NATIVE size, then the SCALED sizes nearest to the current
    /// width. Sorted by logical width ascending (Larger Text → More Space).
    ///
    /// The current mode is listed even when it is SOFT, so the list always shows where you are.
    public static func recommendedModes(_ modes: [DisplayMode], current: DisplayMode?,
                                        native: (width: Int, height: Int), limit: Int = 6) -> [DisplayMode] {
        let hz = current?.refreshRate ?? modes.filter(\.isUsable).map(\.refreshRate).max() ?? 0
        let rank: (DisplayMode) -> Int = {
            switch $0.sharpness(native: native) {
            case .crisp: 0
            case .native: 1
            case .scaled: 2
            case .soft: 3
            }
        }
        // Best candidate per logical size.
        var bySize: [Size: DisplayMode] = [:]
        for mode in modes where mode.isUsable && abs(mode.refreshRate - hz) < 0.5
            && mode.sharpness(native: native) != .soft {
            let key = Size(mode.width, mode.height)
            guard let existing = bySize[key] else { bySize[key] = mode; continue }
            if (rank(mode), -mode.depth, mode.modeNumber) < (rank(existing), -existing.depth, existing.modeNumber) {
                bySize[key] = mode
            }
        }
        var pool = Array(bySize.values)
        if let current {
            let key = Size(current.width, current.height)
            if let best = bySize[key], best.modeNumber != current.modeNumber, rank(best) < rank(current) {
                // A sharper variant of the same size stays listed beside where you are.
                pool.append(current)
            } else {
                bySize[key] = current
                pool = Array(bySize.values)
            }
        }

        let anchor = current?.width ?? pool.filter { rank($0) == 0 }.map(\.width).max() ?? 0
        let candidates = pool.sorted { a, b in
            let ka = (a.modeNumber == current?.modeNumber ? -1 : rank(a), abs(a.width - anchor), a.width)
            let kb = (b.modeNumber == current?.modeNumber ? -1 : rank(b), abs(b.width - anchor), b.width)
            return ka < kb
        }
        return candidates.prefix(max(0, limit)).sorted {
            ($0.width, $0.height, $0.modeNumber) < ($1.width, $1.height, $1.modeNumber)
        }
    }

    private struct Size: Hashable {
        let width: Int
        let height: Int
        init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }
    }
}
