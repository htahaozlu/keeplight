import Foundation

/// Pure DDC/CI packet encoding/decoding (no I/O), unit-testable.
public enum DDCPacket {
    static let hostAddress: UInt8 = 0x51
    static let displayAddress: UInt8 = 0x6E
    static let replySource: UInt8 = 0x50

    /// Bytes to write at I2C data address 0x51 for Set VCP Feature.
    public static func setVCP(_ code: VCP, value: UInt16) -> [UInt8] {
        seal([0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Bytes to write at I2C data address 0x51 for Get VCP Feature request.
    public static func getVCPRequest(_ code: VCP) -> [UInt8] {
        seal([0x82, 0x01, code.rawValue])
    }

    /// Parses a Get VCP Feature reply. Returns (current, maximum).
    /// The frame may or may not begin with the 0x6E source byte and may carry trailing bytes.
    public static func parseGetVCPReply(_ reply: [UInt8], for code: VCP) throws -> (current: UInt16, maximum: UInt16) {
        // Opcode 0x02 follows the 0x88 length byte; result, vcp, type, max(2), cur(2) follow.
        guard let i = reply.indices.first(where: { i in
            i >= 1 && i + 8 < reply.count && reply[i] == 0x02 && reply[i - 1] == 0x88
                && reply[i + 2] == code.rawValue
        }) else {
            throw DisplayError.ddc("malformed reply for VCP \(code)")
        }
        // The checksum always covers the 0x6E source byte, whether or not the read returned it.
        let expected = reply[(i - 1)...(i + 7)].reduce(replySource ^ displayAddress, ^)
        guard expected == reply[i + 8] else { throw DisplayError.ddc("reply checksum mismatch for VCP \(code)") }
        guard reply[i + 1] == 0 else {
            throw DisplayError.ddc("unsupported VCP 0x" + String(format: "%02X", code.rawValue))
        }
        let maximum = UInt16(reply[i + 4]) << 8 | UInt16(reply[i + 5])
        let current = UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
        return (current, maximum)
    }

    private static func seal(_ payload: [UInt8]) -> [UInt8] {
        payload + [payload.reduce(displayAddress ^ hostAddress, ^)]
    }
}
