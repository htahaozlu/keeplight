import CoreGraphics
import Foundation
import IOKit

/// An external-display IOAVService paired with the framebuffer attributes found beside it.
struct AVServiceEntry: @unchecked Sendable {
    let service: CFTypeRef
    let manufacturerID: String
    let productID: Int
    let serialNumber: Int
    let productName: String
    /// IOService-plane path of the paired framebuffer (`…/dispext0@…/AppleCLCD2`).
    let framebufferPath: String?
}

enum AVServiceDiscovery {
    /// PNP manufacturer code as reported by CoreGraphics' vendor number.
    static func pnpCode(_ id: String) -> UInt32? {
        let u = Array(id.uppercased().utf8)
        guard u.count == 3, u.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return UInt32(u[0] - 64) << 10 | UInt32(u[1] - 64) << 5 | UInt32(u[2] - 64)
    }

    static func entries() -> [AVServiceEntry] {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var framebuffers: [Framebuffer] = []
        var proxies: [(service: CFTypeRef, path: String?, precedingFramebuffers: Int)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            switch name(of: entry) {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                let attrs = property(entry, "DisplayAttributes") as? [String: Any]
                framebuffers.append(Framebuffer(path: path(of: entry),
                                                attributes: attrs?["ProductAttributes"] as? [String: Any] ?? [:]))
            case "DCPAVServiceProxy":
                guard property(entry, "Location") as? String == "External",
                      let create = PrivateSymbols.ioAVServiceCreateWithService,
                      let ref = create(kCFAllocatorDefault, entry)
                else { continue }
                proxies.append((Unmanaged<AnyObject>.fromOpaque(ref).takeRetainedValue(), path(of: entry),
                                framebuffers.count))
            default: break
            }
        }
        return proxies.compactMap { proxy in
            guard let fb = framebuffer(forProxyAt: proxy.path, in: framebuffers,
                                       preceding: proxy.precedingFramebuffers) else { return nil }
            let a = fb.attributes
            return AVServiceEntry(
                service: proxy.service,
                manufacturerID: a["ManufacturerID"] as? String ?? "",
                productID: (a["ProductID"] as? NSNumber)?.intValue ?? 0,
                serialNumber: (a["SerialNumber"] as? NSNumber)?.intValue ?? 0,
                productName: a["ProductName"] as? String ?? "",
                framebufferPath: fb.path)
        }
    }

    struct Framebuffer {
        let path: String?
        let attributes: [String: Any]
    }

    /// A proxy path names its framebuffer node (`…/dispext0:dcpav-service-epic:0/DCPAVServiceProxy`
    /// ↔ `…/dispext0@8000000/AppleCLCD2`). Without that node, fall back to the framebuffer
    /// enumerated last before the proxy.
    static func framebuffer(forProxyAt proxyPath: String?, in framebuffers: [Framebuffer],
                            preceding: Int) -> Framebuffer? {
        if let node = proxyPath?.split(separator: "/").first(where: { $0.contains(":dcpav") })?
            .split(separator: ":").first {
            let byNode = framebuffers.filter { $0.path?.contains("/\(node)@") == true }
            if byNode.count == 1 { return byNode[0] }
        }
        return preceding > 0 ? framebuffers[preceding - 1] : nil
    }

    /// Pairs `display` with its service: exact framebuffer path, else a unique
    /// vendor+product match, else the sole service when only one external display exists.
    static func match(_ display: DisplayInfo, in services: [AVServiceEntry]) -> AVServiceEntry? {
        guard !display.isBuiltin, !services.isEmpty else { return nil }
        if let location = displayLocation(display.id) {
            let byPath = services.filter { $0.framebufferPath == location }
            if byPath.count == 1 { return byPath[0] }
        }
        // A service whose framebuffer another online display owns is never a candidate.
        let claimed = Set(DisplayManager.onlineDisplayIDs().filter { $0 != display.id }.compactMap(displayLocation))
        let candidates = services.filter { $0.framebufferPath.map { !claimed.contains($0) } ?? true }
        let scored = candidates.compactMap { s in score(display, s).map { (entry: s, score: $0) } }
        if let top = scored.map(\.score).max(), top >= 8 {
            let best = scored.filter { $0.score == top }
            return best.count == 1 ? best[0].entry : nil
        }
        if candidates.count == 1, externalDisplayCount() == 1, score(display, candidates[0]) != nil {
            return candidates[0]
        }
        return nil
    }

    /// CoreDisplay's `IODisplayLocation`: the IOService path of the display's framebuffer.
    static func displayLocation(_ id: CGDirectDisplayID) -> String? {
        guard let create = PrivateSymbols.coreDisplayCreateInfoDictionary,
              let info = create(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        return info["IODisplayLocation"] as? String
    }

    /// nil when both sides report different non-zero serial numbers.
    static func score(_ display: DisplayInfo, _ s: AVServiceEntry) -> Int? {
        if s.serialNumber != 0, display.serialNumber != 0,
           UInt32(truncatingIfNeeded: s.serialNumber) != display.serialNumber { return nil }
        var score = 0
        if let code = pnpCode(s.manufacturerID), code == display.vendorID { score += 4 }
        if s.productID != 0, UInt32(truncatingIfNeeded: s.productID) == display.productID { score += 4 }
        if s.serialNumber != 0, UInt32(truncatingIfNeeded: s.serialNumber) == display.serialNumber { score += 2 }
        if !s.productName.isEmpty, !display.name.isEmpty,
           display.name.localizedCaseInsensitiveContains(s.productName)
            || s.productName.localizedCaseInsensitiveContains(display.name) { score += 1 }
        return score
    }

    static func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    static func name(of entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func path(of entry: io_registry_entry_t) -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buf) == KERN_SUCCESS else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
