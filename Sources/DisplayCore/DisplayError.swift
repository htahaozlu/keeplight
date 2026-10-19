import CoreGraphics
import IOKit

public enum DisplayError: Error, CustomStringConvertible, Sendable {
    case displayNotFound(String)
    case modeNotFound(String)
    case coreGraphics(CGError, String)
    case ioKit(IOReturn, String)
    case unavailable(String)
    case invalidArgument(String)
    case refused(String)
    case ddc(String)
    case notImplemented(String)

    public var description: String {
        switch self {
        case .displayNotFound(let s): "display not found: \(s)"
        case .modeNotFound(let s): "mode not found: \(s)"
        case .coreGraphics(let e, let op): "\(op) failed (CGError \(e.rawValue))"
        case .ioKit(let r, let op): "\(op) failed (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .unavailable(let s): "unavailable: \(s)"
        case .invalidArgument(let s): "invalid argument: \(s)"
        case .refused(let s): "refused: \(s)"
        case .ddc(let s): "DDC: \(s)"
        case .notImplemented(let s): "not implemented: \(s)"
        }
    }
}

extension DisplayError {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

@inline(__always)
func check(_ error: CGError, _ op: String) throws {
    guard error == .success else { throw DisplayError.coreGraphics(error, op) }
}
