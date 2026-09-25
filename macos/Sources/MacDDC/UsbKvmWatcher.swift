import Foundation
import IOKit
import IOKit.usb
import KVMCore

/// Feeds a `PresenceKvmStateProvider` from IOKit USB attach/detach notifications.
/// Matches by vendor/product ID, not name: right after a KVM switch, hubs show up
/// briefly as unnamed `IOUSBHostDevice` entries.
public final class UsbKvmWatcher {
    public let provider: PresenceKvmStateProvider
    private let config: KvmDetectionConfig
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init(config: KvmDetectionConfig, log: Log = .shared) {
        self.config = config
        provider = PresenceKvmStateProvider(config: config, log: log)
    }

    /// Registers notifications on `runLoop` (the main run loop for apps and `kvmctl kvm watch`).
    public func start(on runLoop: RunLoop = .main) {
        guard port == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        self.port = port
        CFRunLoopAddSource(runLoop.getCFRunLoop(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for match in Set(config.usbDevices) {
            for (type, callback) in [(kIOFirstMatchNotification, Self.appeared), (kIOTerminatedNotification, Self.disappeared)] {
                var iterator = io_iterator_t()
                let dict = Self.matching(match)
                guard IOServiceAddMatchingNotification(port, type, dict, callback, context, &iterator) == KERN_SUCCESS else { continue }
                iterators.append(iterator)
                // Draining arms the notification; for first-match it also reports devices already attached.
                (type == kIOFirstMatchNotification ? Self.appeared : Self.disappeared)(context, iterator)
            }
        }
        provider.initialEnumerationComplete()
    }

    public func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    deinit { stop() }

    private static func matching(_ match: UsbDeviceMatch) -> CFMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict[kUSBVendorID] = match.vendorId
        if let product = match.productId { dict[kUSBProductID] = product }
        return dict as CFMutableDictionary
    }

    private static let appeared: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let watcher = Unmanaged<UsbKvmWatcher>.fromOpaque(context).takeUnretainedValue()
        watcher.drain(iterator) { watcher.provider.deviceAppeared($0, description: $1) }
    }

    private static let disappeared: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let watcher = Unmanaged<UsbKvmWatcher>.fromOpaque(context).takeUnretainedValue()
        watcher.drain(iterator) { watcher.provider.deviceDisappeared($0, description: $1) }
    }

    private func drain(_ iterator: io_iterator_t, _ report: (UInt64, String) -> Void) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &name)
            report(id, String(cString: name))
            IOObjectRelease(service)
        }
    }
}
