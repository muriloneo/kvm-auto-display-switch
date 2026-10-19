import AppKit
import ApplicationServices
import ColorSync
import KVMCore

/// Puts the display arrangement and window frames back after the monitor returns.
/// The reference monitor drops off this Mac for about 2 s when it switches back to HDMI,
/// and macOS parks its windows on the built-in display meanwhile and leaves them there.
/// So: save when the KVM leaves, restore once the displays settle after it returns.
/// Moving other apps' windows needs Accessibility permission; the arrangement does not.
final class LayoutKeeper {
    private struct SavedWindow { let element: AXUIElement; let frame: CGRect }
    private struct Snapshot { let origins: [String: CGPoint]; let windows: [SavedWindow] }

    /// Displays add/remove in bursts; restore only after this much quiet.
    private static let settleDelay: TimeInterval = 2.0
    /// Auto-restore only this long after the KVM came back, so a later unrelated
    /// hot-plug never applies a stale layout.
    private static let returnWindow: TimeInterval = 30

    private let log: Log
    private let queue = DispatchQueue(label: "kvm.layout")
    private var snapshot: Snapshot?
    private var returnedAt: Date?
    private var pending: DispatchWorkItem?

    init(log: Log = .shared) {
        self.log = log
        // One hung app must not stall a save or restore for the 6 s default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    var canMoveWindows: Bool { AXIsProcessTrusted() }
    var hasSnapshot: Bool { queue.sync { snapshot != nil } }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Records every display origin and window frame. Call while the layout is still right.
    func save(reason: String) {
        queue.async { [self] in
            let origins = Self.activeDisplays().mapValues { CGDisplayBounds($0).origin }
            let trusted = AXIsProcessTrusted()
            let windows = trusted ? Self.windows() : []
            snapshot = Snapshot(origins: origins, windows: windows)
            returnedAt = nil
            log.info("layout saved (\(reason)): \(origins.count) displays, \(windows.count) windows" + (trusted ? "" : " (no Accessibility permission, windows skipped)"))
        }
    }

    /// The KVM is back on this computer: the next display hot-plugs are the monitor returning.
    func kvmReturned() {
        queue.async { [self] in returnedAt = Date() }
    }

    /// Call on every display add/remove.
    func displaysChanged() {
        queue.async { [self] in
            guard snapshot != nil, let returnedAt, Date().timeIntervalSince(returnedAt) < Self.returnWindow else { return }
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.restore(reason: "display returned") }
            pending = item
            queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
        }
    }

    func restoreNow() {
        queue.async { [self] in restore(reason: "menu") }
    }

    /// Runs on `queue`. Does nothing until every saved display is back online.
    private func restore(reason: String) {
        guard let snapshot else { return }
        let displays = Self.activeDisplays()
        let missing = snapshot.origins.keys.filter { displays[$0] == nil }
        guard missing.isEmpty else {
            log.info("layout restore (\(reason)) waiting: \(missing.count) saved display(s) not back yet")
            return
        }

        let drifted = snapshot.origins.filter { CGDisplayBounds(displays[$0.key]!).origin != $0.value }
        var config: CGDisplayConfigRef?
        if !drifted.isEmpty, CGBeginDisplayConfiguration(&config) == .success {
            for (uuid, origin) in snapshot.origins {
                CGConfigureDisplayOrigin(config, displays[uuid]!, Int32(origin.x), Int32(origin.y))
            }
            let result = CGCompleteDisplayConfiguration(config, .permanently)
            log.info("layout: display arrangement restored (\(drifted.count) moved) result=\(result.rawValue)")
            Thread.sleep(forTimeInterval: 0.5) // let the window server apply it before moving windows
        }

        guard AXIsProcessTrusted() else {
            log.info("layout restore (\(reason)): windows skipped, no Accessibility permission")
            return
        }
        var moved = 0
        var gone = 0
        for window in snapshot.windows {
            guard let now = Self.frame(of: window.element) else { gone += 1; continue }
            guard now != window.frame else { continue }
            Self.setFrame(window.frame, of: window.element)
            moved += 1
        }
        log.info("layout restored (\(reason)): \(moved) of \(snapshot.windows.count) windows moved, \(gone) closed since save")
    }

    // MARK: Displays

    /// Active (non-mirrored) displays keyed by UUID. Display IDs can change across a
    /// hot-plug; the UUID is what macOS itself keys the arrangement by.
    private static func activeDisplays() -> [String: CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [:] }
        var result: [String: CGDirectDisplayID] = [:]
        for id in ids.prefix(Int(count)) where CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            result[CFUUIDCreateString(nil, uuid) as String] = id
        }
        return result
    }

    // MARK: Windows

    /// Standard windows of regular apps on the current Space, minus minimized and full-screen ones.
    private static func windows() -> [SavedWindow] {
        var result: [SavedWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = copy(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows where !isTrue(window, kAXMinimizedAttribute) && !isTrue(window, "AXFullScreen") {
                if let frame = frame(of: window) { result.append(SavedWindow(element: window, frame: frame)) }
            }
        }
        return result
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = axValue(window, kAXPositionAttribute), let extent = axValue(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        // Move first so the size is not clamped to the display the window was parked on,
        // then move again in case the resize shifted it.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func isTrue(_ element: AXUIElement, _ attribute: String) -> Bool {
        (copy(element, attribute) as? Bool) ?? false
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}
