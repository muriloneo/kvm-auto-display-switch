/// A physical monitor as seen by one computer.
public struct Monitor: Hashable {
    /// Stable identity. On macOS this is the framebuffer's EDID UUID.
    public let id: String
    public let name: String
    public let manufacturer: String?
    /// Human-readable link description, e.g. "DP -> HDMI (built-in HDMI port)".
    public let connection: String?
    /// False when the platform found the display but has no DDC channel to it.
    public let ddcAvailable: Bool

    public init(id: String, name: String, manufacturer: String?, connection: String?, ddcAvailable: Bool) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.connection = connection
        self.ddcAvailable = ddcAvailable
    }
}

public enum DDCError: Error, CustomStringConvertible, Equatable {
    case notAvailable(String)
    case monitorNotFound(String)
    /// The monitor answered with a DDC null message: alive on the bus, but not serving
    /// requests. Monitors that only speak DDC on their active input do this.
    case nullReply
    case unsupported(UInt8)
    case io(String)
    case invalidReply(String)

    public var description: String {
        switch self {
        case .notAvailable(let why): return "DDC/CI is not available for this monitor: \(why)"
        case .monitorNotFound(let id): return "monitor not found: \(id)"
        case .nullReply: return "monitor sent a DDC null reply (it is not serving DDC on this computer's input)"
        case .unsupported(let code): return String(format: "monitor reports VCP 0x%02X as unsupported", code)
        case .io(let why): return "I2C error: \(why)"
        case .invalidReply(let why): return "invalid DDC reply: \(why)"
        }
    }
}

/// Platform DDC backend. Deliberately low level: raw VCP 0x60 values only.
/// Naming, verification and retry policy live in `InputController`.
public protocol MonitorBackend: AnyObject {
    func listMonitors() throws -> [Monitor]
    func capabilities(of monitor: Monitor) throws -> Capabilities
    /// Raw VCP 0x60 read. Throws `.nullReply` when the monitor is not serving DDC here.
    func readInputSource(of monitor: Monitor) throws -> (current: UInt16, maximum: UInt16)
    /// Raw VCP 0x60 write. Success only means the bytes went out on the bus.
    func writeInputSource(_ value: UInt16, to monitor: Monitor) throws
}
