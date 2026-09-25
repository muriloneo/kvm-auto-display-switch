import Foundation

/// KVM state from device presence. A platform watcher reports devices appearing and
/// disappearing. Any device present means `presentMeans`, none means `absentMeans`.
///
/// Changes are debounced: while re-enumerating, a KVM briefly drops and re-adds hubs
/// (seen: hubs appear as unnamed devices, vanish, then reappear within about 1 s).
/// The initial enumeration only sets the starting state and never notifies, so launching
/// the agent does not switch the monitor.
public final class PresenceKvmStateProvider: KvmStateProvider {
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let config: KvmDetectionConfig
    private let debounce: TimeInterval
    private let schedule: Scheduler
    private let log: Log
    private let lock = NSLock()

    private var present: Set<UInt64> = []
    private var state = KvmState(activeComputer: nil)
    private var ready = false
    private var generation = 0
    private var handlers: [UUID: (KvmState) -> Void] = [:]

    public init(config: KvmDetectionConfig, debounce: TimeInterval = 0.4, log: Log = .shared,
                schedule: @escaping Scheduler = { delay, work in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.config = config
        self.debounce = debounce
        self.schedule = schedule
        self.log = log
    }

    public func getState() -> KvmState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func subscribe(_ handler: @escaping (KvmState) -> Void) -> KvmSubscription {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return KvmSubscription { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.handlers[id] = nil; self.lock.unlock()
        }
    }

    /// Call once the watcher has reported every device that was already attached.
    public func initialEnumerationComplete() {
        lock.lock()
        state = computedState()
        ready = true
        let now = state
        let count = present.count
        lock.unlock()
        log.info("kvm detector ready: \(now.activeComputer ?? "unknown") (\(count) KVM devices present)")
    }

    public func deviceAppeared(_ id: UInt64, description: String) {
        lock.lock(); present.insert(id); lock.unlock()
        log.debug("kvm device appeared: \(description) id=\(id)")
        changed()
    }

    public func deviceDisappeared(_ id: UInt64, description: String) {
        lock.lock(); present.remove(id); lock.unlock()
        log.debug("kvm device disappeared: \(description) id=\(id)")
        changed()
    }

    private func computedState() -> KvmState {
        KvmState(activeComputer: present.isEmpty ? config.absentMeans : config.presentMeans)
    }

    private func changed() {
        lock.lock()
        guard ready else { lock.unlock(); return }
        generation += 1
        let mine = generation
        lock.unlock()
        schedule(debounce) { [weak self] in self?.settle(generation: mine) }
    }

    private func settle(generation mine: Int) {
        lock.lock()
        guard mine == generation else { lock.unlock(); return } // superseded by a newer change
        let next = computedState()
        guard next != state else { lock.unlock(); return }
        state = next
        let targets = Array(handlers.values)
        lock.unlock()
        log.info("kvm switched: active computer = \(next.activeComputer ?? "unknown")")
        targets.forEach { $0(next) }
    }
}
