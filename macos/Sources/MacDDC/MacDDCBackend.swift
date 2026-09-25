import CIOAVService
import Foundation
import IOKit
import KVMCore

/// Apple Silicon DDC/CI backend over the private IOAVService I2C API.
///
/// Discovery pairs two IORegistry nodes that share a DCP instance prefix:
///   dispext0 / IOMobileFramebufferShim           -> DisplayAttributes, EDID UUID, Transport
///   dispext0:dcpav-service-epic / DCPAVServiceProxy -> the I2C channel
/// Every call re-discovers, so hot-plug and reconnects need no cache invalidation.
public final class MacDDCBackend: MonitorBackend {
    private let log: Log
    /// All I2C traffic is serialised: interleaved transactions corrupt replies.
    private let bus = NSLock()
    private var capabilitiesCache: [String: Capabilities] = [:]

    public var writeToReadDelay: useconds_t = 50_000
    public var readRetries = 4

    public init(log: Log = .shared) { self.log = log }

    // MARK: Discovery

    private struct Framebuffer {
        var name: String?
        var manufacturer: String?
        var edidUUID: String?
        var transport: String?
    }

    private struct Found {
        let monitor: Monitor
        let service: io_service_t
    }

    private func discover() -> [Found] {
        var framebuffers: [String: Framebuffer] = [:]
        var services: [(prefix: String, location: String, service: io_service_t)] = []

        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            log.error("IORegistryCreateIterator failed")
            return []
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let className = Self.className(entry)
            if className == "IOMobileFramebufferShim" || className == "AppleCLCD2" {
                if let prefix = Self.parentName(entry) {
                    framebuffers[prefix] = Self.framebufferInfo(entry)
                }
                IOObjectRelease(entry)
            } else if className == "DCPAVServiceProxy" {
                let location = Self.stringProperty(entry, "Location") ?? "?"
                let prefix = Self.parentName(entry).map { String($0.split(separator: ":").first ?? "") } ?? ""
                services.append((prefix, location, entry))
            } else {
                IOObjectRelease(entry)
            }
        }

        var found: [Found] = []
        for (index, s) in services.enumerated() {
            guard s.location == "External" else { IOObjectRelease(s.service); continue }
            let fb = framebuffers[s.prefix] ?? Framebuffer()
            let monitor = Monitor(
                id: fb.edidUUID ?? "\(s.prefix.isEmpty ? "external" : s.prefix)-\(index)",
                name: fb.name ?? "Unknown external display",
                manufacturer: fb.manufacturer,
                connection: fb.transport,
                ddcAvailable: true)
            found.append(Found(monitor: monitor, service: s.service))
        }
        log.debug("discovery: \(framebuffers.count) framebuffers, \(services.count) AV services, \(found.count) external")
        return found
    }

    private static func framebufferInfo(_ entry: io_registry_entry_t) -> Framebuffer {
        var fb = Framebuffer()
        fb.edidUUID = stringProperty(entry, "EDID UUID")
        if let attrs = property(entry, "DisplayAttributes") as? [String: Any],
           let product = attrs["ProductAttributes"] as? [String: Any] {
            fb.name = product["ProductName"] as? String
            fb.manufacturer = product["ManufacturerID"] as? String
        }
        if let transport = property(entry, "Transport") as? [String: Any] {
            let up = transport["Upstream"] as? String ?? "?"
            let down = transport["Downstream"] as? String ?? "?"
            fb.transport = up == down ? up : "\(up) -> \(down)"
        }
        return fb
    }

    private static func className(_ entry: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buffer)
        return String(cString: buffer)
    }

    private static func parentName(_ entry: io_registry_entry_t) -> String? {
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    // MARK: MonitorBackend

    public func listMonitors() throws -> [Monitor] {
        let found = discover()
        found.forEach { IOObjectRelease($0.service) }
        return found.map(\.monitor)
    }

    public func capabilities(of monitor: Monitor) throws -> Capabilities {
        if let cached = capabilitiesCache[monitor.id] { return cached }
        let raw = try withService(monitor) { service in
            var data: [UInt8] = []
            var offset: UInt16 = 0
            for _ in 0..<64 {
                let reply = try transact(service, request: DDC.capabilitiesRequest(offset: offset), replyLength: 38)
                guard case .capabilities(let at, let chunk) = reply, at == offset else {
                    throw DDCError.invalidReply("capabilities fragment at \(offset): \(reply)")
                }
                if chunk.isEmpty { break }
                data += chunk
                offset += UInt16(chunk.count)
            }
            return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        }
        log.debug("capabilities monitor=\(monitor.name) raw=\(raw)")
        let caps = Capabilities(parsing: raw)
        capabilitiesCache[monitor.id] = caps
        return caps
    }

    public func readInputSource(of monitor: Monitor) throws -> (current: UInt16, maximum: UInt16) {
        try withService(monitor) { service in
            let reply = try transact(service, request: DDC.vcpGetRequest(code: DDC.vcpInputSource), replyLength: 12)
            switch reply {
            case .vcp(DDC.vcpInputSource, let current, let maximum): return (current, maximum)
            case .unsupported(let code): throw DDCError.unsupported(code)
            default: throw DDCError.invalidReply("\(reply)")
            }
        }
    }

    public func writeInputSource(_ value: UInt16, to monitor: Monitor) throws {
        try withService(monitor) { service in
            try write(service, DDC.vcpSetRequest(code: DDC.vcpInputSource, value: value))
        }
    }

    // MARK: I2C

    private func withService<T>(_ monitor: Monitor, _ body: (IOAVService) throws -> T) throws -> T {
        let found = discover()
        defer { found.forEach { IOObjectRelease($0.service) } }
        guard let match = found.first(where: { $0.monitor.id == monitor.id }) else {
            throw DDCError.monitorNotFound(monitor.id)
        }
        guard let service = IOAVServiceCreateWithService(kCFAllocatorDefault, match.service) else {
            throw DDCError.notAvailable("IOAVServiceCreateWithService returned nil")
        }
        bus.lock()
        defer { bus.unlock() }
        return try body(service)
    }

    private func write(_ service: IOAVService, _ packet: [UInt8]) throws {
        var bytes = packet
        var result: IOReturn = kIOReturnError
        for attempt in 1...3 {
            result = IOAVServiceWriteI2C(service, DDC.chipAddress, UInt32(DDC.hostAddress), &bytes, UInt32(bytes.count))
            log.debug("i2c write [\(hex(packet))] attempt=\(attempt) ioreturn=\(String(format: "0x%x", result))")
            if result == kIOReturnSuccess { return }
            usleep(10_000)
        }
        throw DDCError.io(String(format: "IOAVServiceWriteI2C returned 0x%x", result))
    }

    /// Write a request, read the reply, retry on transport or checksum errors.
    /// A checksum-valid null reply is final: retrying after one only returns stale
    /// buffer bytes (observed on the 34D901: the tail of its capabilities string).
    private func transact(_ service: IOAVService, request: [UInt8], replyLength: Int) throws -> DDC.Reply {
        var last = DDC.Reply.invalid("no attempt")
        for attempt in 1...readRetries {
            try write(service, request)
            usleep(writeToReadDelay)
            var buffer = [UInt8](repeating: 0, count: replyLength)
            let result = IOAVServiceReadI2C(service, DDC.chipAddress, UInt32(DDC.hostAddress), &buffer, UInt32(replyLength))
            guard result == kIOReturnSuccess else {
                log.debug(String(format: "i2c read attempt=%d ioreturn=0x%x", attempt, result))
                last = .invalid(String(format: "IOAVServiceReadI2C returned 0x%x", result))
                usleep(40_000)
                continue
            }
            let reply = DDC.parseReply(buffer)
            log.debug("i2c read attempt=\(attempt) [\(hex(buffer))] -> \(reply)")
            switch reply {
            case .null:
                throw DDCError.nullReply
            case .invalid:
                // Garbage usually means the monitor is still busy with a previous transaction
                // (DDC/CI wants >= 50 ms between them); back off a little more each time.
                last = reply
                usleep(50_000 * useconds_t(attempt))
            default:
                return reply
            }
        }
        throw DDCError.invalidReply("\(last)")
    }
}
