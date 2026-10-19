import CoreGraphics
import Foundation
import os

/// Display identity that survives reboots, unlike `CGDirectDisplayID`.
///
/// Format `vendor:product:serial`: the PNP vendor code (`DEL`), the product code as four
/// hex digits, and the EDID serial string when present, else the numeric serial. When two
/// online displays share that triple, each gets `:` plus a short hash of its
/// `IODisplayLocation`; without a location (or without any vendor/product) the CG UUID is used.
/// A display with no serial at all always carries the location hash, so its identity does
/// not change when an identical twin is plugged in or removed.
public enum Fingerprint {
    public struct Input: Hashable, Sendable {
        public var displayID: CGDirectDisplayID
        public var vendorID: UInt32
        public var productID: UInt32
        public var serialNumber: UInt32
        public var serialString: String?
        public var uuid: String?

        public init(displayID: CGDirectDisplayID, vendorID: UInt32, productID: UInt32, serialNumber: UInt32,
                    serialString: String? = nil, uuid: String? = nil) {
            self.displayID = displayID
            self.vendorID = vendorID
            self.productID = productID
            self.serialNumber = serialNumber
            self.serialString = serialString
            self.uuid = uuid
        }
    }

    /// `vendor:product:serial`, or nil when the display reports neither vendor nor product.
    public static func base(vendorID: UInt32, productID: UInt32, serialNumber: UInt32,
                            serialString: String?) -> String? {
        guard vendorID != 0 || productID != 0 else { return nil }
        let serial = serialString.map(sanitize).flatMap { $0.isEmpty ? nil : $0 } ?? String(serialNumber)
        return "\(vendorCode(vendorID)):\(hex(productID)):\(serial)"
    }

    /// Fingerprints for a set of online displays. `location` is only asked for displays
    /// whose triple is shared with another display in `inputs`.
    public static func assign(_ inputs: [Input],
                              location: (CGDirectDisplayID) -> String?) -> [CGDirectDisplayID: String] {
        let bases = inputs.map {
            base(vendorID: $0.vendorID, productID: $0.productID, serialNumber: $0.serialNumber,
                 serialString: $0.serialString)
        }
        var counts: [String: Int] = [:]
        for case let b? in bases { counts[b, default: 0] += 1 }
        var result: [CGDirectDisplayID: String] = [:]
        for (input, base) in zip(inputs, bases) {
            let fallback = input.uuid ?? "id:\(input.displayID)"
            guard let base else {
                result[input.displayID] = fallback
                continue
            }
            let shared = counts[base, default: 0] > 1
            if shared || hasNoSerial(input) {
                if let loc = location(input.displayID) {
                    result[input.displayID] = "\(base):\(shortHash(loc))"
                    continue
                }
                if shared {
                    result[input.displayID] = fallback
                    continue
                }
            }
            result[input.displayID] = base
        }
        return result
    }

    /// Three-letter PNP code when the vendor number encodes one, else `0x` + hex.
    public static func vendorCode(_ vendor: UInt32) -> String {
        let codes = [(vendor >> 10) & 31, (vendor >> 5) & 31, vendor & 31]
        guard vendor >> 15 == 0, codes.allSatisfy({ (1...26).contains($0) }) else { return "0x" + hex(vendor) }
        return String(decoding: codes.map { UInt8($0 + 64) }, as: UTF8.self)
    }

    /// First 6 hex digits of FNV-1a (32-bit); stable across processes, unlike `Hasher`.
    public static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x0100_0193
        }
        return String(String(format: "%08x", hash).prefix(6))
    }

    /// No usable serial: no serial string and a numeric serial that is zero or a placeholder
    /// with four identical bytes (0x01010101, 0xFFFFFFFF…) that identical monitors share.
    private static func hasNoSerial(_ input: Input) -> Bool {
        let n = input.serialNumber
        let placeholder = n == (n & 0xFF) &* 0x0101_0101
        return placeholder && (input.serialString.map(sanitize) ?? "").isEmpty
    }

    private static func hex(_ value: UInt32) -> String {
        let s = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - s.count)) + s
    }

    private static func sanitize(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-")
    }
}

/// EDID-derived identity parts, read once per display per process (EDID reads walk the
/// IORegistry and can take tens of milliseconds).
enum IdentityCache {
    private struct Key: Hashable {
        let id: CGDirectDisplayID
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    private struct Parts {
        var serialString: String??
        var location: String??
    }

    private static let state = OSAllocatedUnfairLock(initialState: [Key: Parts]())

    private static func key(_ d: DisplayInfo) -> Key {
        Key(id: d.id, vendor: d.vendorID, product: d.productID, serial: d.serialNumber)
    }

    static func serialString(for display: DisplayInfo) -> String? {
        let k = key(display)
        if let cached = state.withLock({ $0[k]?.serialString }) { return cached }
        let value = EDID.read(for: display)?.serialString
        state.withLock { $0[k, default: Parts()].serialString = .some(value) }
        return value
    }

    static func location(for display: DisplayInfo) -> String? {
        let k = key(display)
        if let cached = state.withLock({ $0[k]?.location }) { return cached }
        let value = AVServiceDiscovery.displayLocation(display.id)
        state.withLock { $0[k, default: Parts()].location = .some(value) }
        return value
    }
}
