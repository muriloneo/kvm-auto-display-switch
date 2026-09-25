/// DDC/CI packet framing (VESA DDC/CI 1.1). Pure byte manipulation, no I/O.
///
/// Write packets are sent to I2C chip 0x37 with the host source address 0x51
/// as the "offset" argument, so the bytes built here start at the length byte.
/// Replies are read back starting at the monitor's source address (0x6E).
public enum DDC {
    public static let chipAddress: UInt32 = 0x37
    public static let hostAddress: UInt8 = 0x51
    static let displayAddress: UInt8 = 0x6E
    static let replyChecksumSeed: UInt8 = 0x50

    public static let vcpInputSource: UInt8 = 0x60

    static func xor(_ seed: UInt8, _ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var packet = [0x80 | UInt8(payload.count)] + payload
        packet.append(xor(displayAddress ^ hostAddress, packet))
        return packet
    }

    public static func vcpGetRequest(code: UInt8) -> [UInt8] {
        frame([0x01, code])
    }

    public static func vcpSetRequest(code: UInt8, value: UInt16) -> [UInt8] {
        frame([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        frame([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }

    public enum Reply: Equatable {
        /// Valid VCP feature reply.
        case vcp(code: UInt8, current: UInt16, maximum: UInt16)
        /// Monitor answered "unsupported VCP code".
        case unsupported(code: UInt8)
        /// DDC/CI null message: the monitor is alive on the bus but has nothing to say.
        /// Many monitors send this when the Mac's input is not the active one.
        case null
        /// Capabilities fragment.
        case capabilities(offset: UInt16, data: [UInt8])
        case invalid(String)
    }

    public static func parseReply(_ bytes: [UInt8]) -> Reply {
        guard bytes.count >= 3 else { return .invalid("short reply (\(bytes.count) bytes)") }
        guard bytes[0] == displayAddress else { return .invalid(String(format: "bad source 0x%02x", bytes[0])) }
        guard bytes[1] & 0x80 != 0 else { return .invalid(String(format: "bad length byte 0x%02x", bytes[1])) }
        let length = Int(bytes[1] & 0x7F)
        guard bytes.count >= 3 + length else { return .invalid("truncated reply: length \(length), got \(bytes.count) bytes") }
        let checksumIndex = 2 + length
        let expected = xor(replyChecksumSeed, bytes[0..<checksumIndex])
        guard bytes[checksumIndex] == expected else {
            return .invalid(String(format: "checksum 0x%02x, expected 0x%02x", bytes[checksumIndex], expected))
        }
        if length == 0 { return .null }

        let body = Array(bytes[2..<checksumIndex])
        switch body[0] {
        case 0x02 where body.count == 8:
            let code = body[2]
            if body[1] != 0x00 { return .unsupported(code: code) }
            let maximum = UInt16(body[4]) << 8 | UInt16(body[5])
            let current = UInt16(body[6]) << 8 | UInt16(body[7])
            return .vcp(code: code, current: current, maximum: maximum)
        case 0xE3 where body.count >= 3:
            let offset = UInt16(body[1]) << 8 | UInt16(body[2])
            return .capabilities(offset: offset, data: Array(body[3...]))
        default:
            return .invalid(String(format: "unexpected opcode 0x%02x, length %d", body[0], length))
        }
    }
}

public func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}
