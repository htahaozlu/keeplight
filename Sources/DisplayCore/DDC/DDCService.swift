import CoreGraphics
import Foundation
import IOKit

/// DDC/CI channel to one external display (Apple silicon, IOAVService).
public final class DDCService: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    /// Number of times a Set VCP packet is sent; some panels drop the first.
    public let writeCycles: Int

    private let service: CFTypeRef
    private let lock = NSLock()

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    /// nil when no IOAVService can be matched to the display (built-in, virtual, Intel, unsupported port).
    public init?(display: DisplayInfo, writeCycles: Int = 2) {
        #if arch(x86_64)
        return nil
        #else
        guard let entry = AVServiceDiscovery.match(display, in: AVServiceDiscovery.entries()) else { return nil }
        self.displayID = display.id
        self.service = entry.service
        self.writeCycles = writeCycles
        #endif
    }

    init(displayID: CGDirectDisplayID, service: CFTypeRef, writeCycles: Int = 2) {
        self.displayID = displayID
        self.service = service
        self.writeCycles = writeCycles
    }

    /// Every external IOAVService with its framebuffer attributes (diagnostics).
    public static func serviceSummaries() -> [String] {
        AVServiceDiscovery.entries().map {
            "\($0.manufacturerID) \($0.productName) product=\($0.productID) serial=\($0.serialNumber)"
        }
    }

    public func read(_ code: VCP) throws -> (current: UInt16, maximum: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        let request = DDCPacket.getVCPRequest(code)
        var lastError: Error = DisplayError.ddc("no reply for VCP \(code)")
        for attempt in 0..<4 {
            if attempt > 0 { usleep(20_000) }
            do {
                try writeLocked(request)
                usleep(50_000)
                guard let readI2C = PrivateSymbols.ioAVServiceReadI2C else {
                    throw PrivateSymbols.missing("IOAVServiceReadI2C")
                }
                var buffer = [UInt8](repeating: 0, count: 12)
                let rc = withExtendedLifetime(service) {
                    readI2C(Self.handle(service), Self.chipAddress, Self.dataAddress, &buffer, UInt32(buffer.count))
                }
                guard rc == KERN_SUCCESS else { throw DisplayError.ioKit(rc, "IOAVServiceReadI2C") }
                return try DDCPacket.parseGetVCPReply(buffer, for: code)
            } catch let DisplayError.ddc(message) where message.hasPrefix("unsupported") {
                throw DisplayError.ddc(message)
            } catch let error as DisplayError where error.isUnavailable {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func write(_ code: VCP, value: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        let packet = DDCPacket.setVCP(code, value: value)
        for cycle in 0..<max(1, writeCycles) {
            if cycle > 0 { usleep(10_000) }
            try writeLocked(packet)
        }
    }

    private func writeLocked(_ packet: [UInt8]) throws {
        guard let writeI2C = PrivateSymbols.ioAVServiceWriteI2C else {
            throw PrivateSymbols.missing("IOAVServiceWriteI2C")
        }
        let rc = withExtendedLifetime(service) {
            writeI2C(Self.handle(service), Self.chipAddress, Self.dataAddress, packet, UInt32(packet.count))
        }
        guard rc == KERN_SUCCESS else { throw DisplayError.ioKit(rc, "IOAVServiceWriteI2C") }
    }

    /// Raw CF pointer for the dlsym-resolved IOAVService calls; the caller keeps `service` alive.
    static func handle(_ service: CFTypeRef) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
    }
}
