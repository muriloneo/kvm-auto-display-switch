import Foundation

/// On-disk config (JSON). Example:
///
/// {
///   "thisComputer": "mac",
///   "monitors": [{
///     "id": "3103FFFF-0000-0000-101F-010380502178",
///     "name": "34D901",
///     "inputs": { "HDMI-1": "0x06", "DP-1": "0x08" },
///     "computers": { "mac": "HDMI-1", "windows": "DP-1" },
///     "quirks": { "ddcOnlyOnActiveInput": true, "inputReadbackUnreliable": true }
///   }],
///   "kvm": {
///     "usbDevices": [{ "vendorId": 13782, "productId": 9488 }],
///     "presentMeans": "mac",
///     "absentMeans": "windows"
///   }
/// }
public struct Configuration: Codable, Equatable {
    /// Which entry of `computers` is the machine this process runs on.
    public var thisComputer: String?
    public var monitors: [MonitorConfig]
    /// How to detect the KVM. Nil = no automatic detection.
    public var kvm: KvmDetectionConfig?

    public init(thisComputer: String? = nil, monitors: [MonitorConfig] = [], kvm: KvmDetectionConfig? = nil) {
        self.thisComputer = thisComputer
        self.monitors = monitors
        self.kvm = kvm
    }

    public func monitorConfig(for monitor: Monitor) -> MonitorConfig? {
        monitors.first { $0.id == monitor.id } ?? monitors.first { $0.id == nil && $0.name == monitor.name }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KVMSwitcher/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct MonitorConfig: Codable, Equatable {
    /// EDID UUID from `kvmctl monitor list`. Nil matches by `name`.
    public var id: String?
    public var name: String?
    /// Input name -> VCP 0x60 value ("0x06"). Overrides the MCCS defaults, which many
    /// monitors do not honour.
    public var inputs: [String: String]?
    /// Computer -> input name. Never assumed; always configured.
    public var computers: [String: String]?
    public var quirks: Quirks?

    public init(id: String? = nil, name: String? = nil, inputs: [String: String]? = nil,
                computers: [String: String]? = nil, quirks: Quirks? = nil) {
        self.id = id
        self.name = name
        self.inputs = inputs
        self.computers = computers
        self.quirks = quirks
    }
}

public struct Quirks: Codable, Equatable {
    /// Monitor only answers DDC on its active input: a null reply means "not on this
    /// computer's input", and switching back must be done from the other computer.
    public var ddcOnlyOnActiveInput: Bool?
    /// VCP 0x60 reads return garbage, so read-back cannot verify a switch.
    public var inputReadbackUnreliable: Bool?

    public init(ddcOnlyOnActiveInput: Bool? = nil, inputReadbackUnreliable: Bool? = nil) {
        self.ddcOnlyOnActiveInput = ddcOnlyOnActiveInput
        self.inputReadbackUnreliable = inputReadbackUnreliable
    }
}

/// USB-presence KVM detection: the KVM moves a group of USB devices between computers,
/// so "any of these present" means the KVM points here.
public struct KvmDetectionConfig: Codable, Equatable {
    public var usbDevices: [UsbDeviceMatch]
    /// Computer to report while any device is present (normally this computer).
    public var presentMeans: String
    /// Computer to report once all devices are gone.
    public var absentMeans: String

    public init(usbDevices: [UsbDeviceMatch], presentMeans: String, absentMeans: String) {
        self.usbDevices = usbDevices
        self.presentMeans = presentMeans
        self.absentMeans = absentMeans
    }
}

public struct UsbDeviceMatch: Codable, Equatable, Hashable {
    public var vendorId: Int
    /// Nil matches any product from the vendor.
    public var productId: Int?

    public init(vendorId: Int, productId: Int? = nil) {
        self.vendorId = vendorId
        self.productId = productId
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case badValue(input: String, value: String)
    public var description: String {
        switch self {
        case .badValue(let input, let value): return "config: input \"\(input)\" has invalid VCP value \"\(value)\""
        }
    }
}
