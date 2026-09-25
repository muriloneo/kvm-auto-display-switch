import Foundation

/// A monitor input: a user-facing name plus the raw VCP 0x60 value that selects it.
public struct InputSource: Hashable, CustomStringConvertible {
    public let name: String
    public let value: UInt16

    public init(name: String, value: UInt16) {
        self.name = name
        self.value = value
    }

    public var description: String { "\(name) (0x\(String(value, radix: 16, uppercase: true).leftPadded(2)))" }

    /// MCCS 2.2 standard names for VCP 0x60 values. Monitors are free to ignore
    /// these (the 34D901 does), so they are only a default when no config exists.
    public static let mccsNames: [UInt16: String] = [
        0x01: "VGA-1", 0x02: "VGA-2", 0x03: "DVI-1", 0x04: "DVI-2",
        0x05: "Composite-1", 0x06: "Composite-2", 0x07: "S-Video-1", 0x08: "S-Video-2",
        0x09: "Tuner-1", 0x0A: "Tuner-2", 0x0B: "Tuner-3",
        0x0C: "Component-1", 0x0D: "Component-2", 0x0E: "Component-3",
        0x0F: "DP-1", 0x10: "DP-2", 0x11: "HDMI-1", 0x12: "HDMI-2", 0x1B: "USB-C",
    ]

    public static func mccs(_ value: UInt16) -> InputSource {
        InputSource(name: mccsNames[value] ?? "Input-0x\(String(value, radix: 16, uppercase: true))", value: value)
    }
}

/// Parses "0x08", "8", or "08h".
public func parseVCPValue(_ text: String) -> UInt16? {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if t.hasPrefix("0x") { return UInt16(t.dropFirst(2), radix: 16) }
    if t.hasSuffix("h") { return UInt16(t.dropLast(), radix: 16) }
    return UInt16(t)
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
