import Foundation

/// Which computer the physical KVM currently routes keyboard/mouse to.
public struct KvmState: Equatable {
    /// A key of `MonitorConfig.computers`, e.g. "mac" or "windows". Nil = unknown.
    public var activeComputer: String?
    public init(activeComputer: String?) { self.activeComputer = activeComputer }
}

/// Source of KVM state. Monitor control never cares how this is detected.
/// Future implementations: USB/HID device presence, serial KVM, network KVM, hotkey.
public protocol KvmStateProvider: AnyObject {
    func getState() -> KvmState
    /// Handler runs on an arbitrary queue. Keep the token alive to stay subscribed.
    func subscribe(_ handler: @escaping (KvmState) -> Void) -> KvmSubscription
}

public final class KvmSubscription {
    private let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

/// State set by hand (menu item, hotkey, CLI). The only provider in the prototype:
/// automatic detection waits until the KVM's USB/HID behaviour is known.
public final class ManualKvmStateProvider: KvmStateProvider {
    private let lock = NSLock()
    private var state = KvmState(activeComputer: nil)
    private var handlers: [UUID: (KvmState) -> Void] = [:]

    public init() {}

    public func getState() -> KvmState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func set(activeComputer: String?) {
        lock.lock()
        let next = KvmState(activeComputer: activeComputer)
        let changed = next != state
        state = next
        let targets = Array(handlers.values)
        lock.unlock()
        if changed { targets.forEach { $0(next) } }
    }

    public func subscribe(_ handler: @escaping (KvmState) -> Void) -> KvmSubscription {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return KvmSubscription { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.handlers[id] = nil; self.lock.unlock()
        }
    }
}

/// Glue: KVM state -> per-monitor input mapping -> InputController.
public final class AutoSwitcher {
    private let controller: InputController
    private let provider: KvmStateProvider
    private let log: Log
    private var subscription: KvmSubscription?

    public init(controller: InputController, provider: KvmStateProvider, log: Log = .shared) {
        self.controller = controller
        self.provider = provider
        self.log = log
    }

    public func start() {
        subscription = provider.subscribe { [weak self] state in self?.apply(state) }
    }

    public func stop() { subscription = nil }

    /// Called for every state change. Switches each configured monitor to the input of
    /// the newly active computer, unless the monitor is not serving DDC here: then only the
    /// computer on screen can switch it, and sending would just fail.
    public var onResult: ((SwitchResult) -> Void)?

    @discardableResult
    public func apply(_ state: KvmState) -> [SwitchResult] {
        guard let computer = state.activeComputer else { return [] }
        log.info("kvm state: active computer = \(computer)")
        var results: [SwitchResult] = []
        for monitor in (try? controller.backend.listMonitors()) ?? [] {
            guard let target = controller.input(forComputer: computer, on: monitor) else { continue }
            if controller.currentInput(of: monitor) == .notActiveHere {
                log.info("auto switch skipped: \(monitor.name) is on another computer's input; that computer must switch it to \(target.name)")
                continue
            }
            let result = controller.switchInput(of: monitor, to: target)
            onResult?(result)
            results.append(result)
        }
        return results
    }
}
