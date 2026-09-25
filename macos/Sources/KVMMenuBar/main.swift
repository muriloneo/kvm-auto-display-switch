import AppKit
import KVMCore
import MacDDC
import ServiceManagement

/// Menu-bar-only agent. No polling: state refreshes when the menu opens, after a
/// switch, on display reconfiguration (hot-plug) and on wake.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Log.shared
    private let backend = MacDDCBackend()
    private lazy var controller = InputController(backend: backend, configuration: Configuration())
    private let work = DispatchQueue(label: "kvm.ddc")

    private var statusItem: NSStatusItem!
    private var monitor: Monitor?
    private var reading: InputReading = .failed(.monitorNotFound("not scanned yet"))
    private var configError: String?
    private var targets: [(label: String, input: InputSource)] = []
    private var switching = false

    private static let autoSwitchKey = "autoSwitch"
    private var watcher: UsbKvmWatcher?
    private var autoSwitcher: AutoSwitcher?
    private var kvmConfig: KvmDetectionConfig?
    private var autoSwitchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoSwitchKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoSwitchKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KVMSwitcher.log")
        log.fileURL = logURL
        log.verbose = ProcessInfo.processInfo.environment["KVM_DEBUG"] != nil
        log.info("menu-bar agent started")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard flags.contains(.addFlag) || flags.contains(.removeFlag), let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.scheduleRefresh(reason: "display reconfigured", after: 1.0)
        }, Unmanaged.passUnretained(self).toOpaque())

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(reason: "wake", after: 2.0)
            }
        }
        scheduleRefresh(reason: "launch", after: 0)
    }

    // MARK: State

    private var pendingRefresh: DispatchWorkItem?

    private func scheduleRefresh(reason: String, after delay: TimeInterval) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh(reason: reason) }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        updateTitle()
    }

    /// Runs DDC off the main thread; applies results on main.
    private func refresh(reason: String) {
        work.async { [self] in
            var configuration = Configuration()
            var loadError: String?
            do { configuration = try Configuration.load() } catch { loadError = "config: \(error)" }
            controller.configuration = configuration
            let monitors = (try? backend.listMonitors()) ?? []
            let chosen = monitors.first { configuration.monitorConfig(for: $0) != nil } ?? monitors.first
            let now = chosen.map { controller.currentInput(of: $0) } ?? .failed(.monitorNotFound("no external DDC monitor"))
            let newTargets = chosen.map(switchTargets) ?? []
            log.info("refresh (\(reason)): monitor=\(chosen?.name ?? "none") input=\(now.summary)")
            DispatchQueue.main.async { [self] in
                monitor = chosen
                reading = now
                targets = newTargets
                configError = loadError
                if configuration.kvm != kvmConfig {
                    kvmConfig = configuration.kvm
                    restartAutoSwitch()
                }
                updateTitle()
            }
        }
    }

    private func updateTitle() {
        let title: String
        if switching {
            title = "◐ switching"
        } else {
            switch reading {
            case .reported(let input), .activeHere(let input?): title = "● \(short(input.name))"
            case .activeHere(nil): title = "● here"
            case .notActiveHere: title = "○ away"
            case .unrecognized: title = "● ?"
            case .failed: title = "KVM"
            }
        }
        statusItem.button?.title = title
    }

    private func short(_ name: String) -> String {
        name.split(separator: "-").first.map(String.init) ?? name
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("KVM Switcher"))
        menu.addItem(.separator())

        guard let monitor else {
            menu.addItem(disabled("No external monitor with DDC/CI"))
            addFooter(menu)
            scheduleRefresh(reason: "menu opened", after: 0)
            return
        }
        menu.addItem(disabled("● \(monitor.name)"))
        menu.addItem(disabled("   Current input: \(reading.summary)"))
        if let configError { menu.addItem(disabled("   \(configError)")) }
        menu.addItem(.separator())
        menu.addItem(disabled("Switch monitor"))

        for target in targets {
            let item = NSMenuItem(title: "   " + target.label, action: #selector(switchInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.input
            item.state = isCurrent(target.input) ? .on : .off
            item.isEnabled = !switching
            menu.addItem(item)
        }
        if case .notActiveHere = reading {
            menu.addItem(disabled("   Monitor is on another computer; switch back from there"))
        }
        if targets.isEmpty { menu.addItem(disabled("   No inputs known; edit Settings")) }

        menu.addItem(.separator())
        if kvmConfig != nil {
            let auto = action("Auto switch", #selector(toggleAutoSwitch), key: "")
            auto.state = autoSwitchEnabled ? .on : .off
            menu.addItem(auto)
            let kvm = watcher?.provider.getState().activeComputer ?? "unknown"
            menu.addItem(disabled("   KVM: \(kvm)"))
        } else {
            let auto = disabled("Auto switch (add a \"kvm\" section in Settings)")
            menu.addItem(auto)
        }
        addFooter(menu)
        scheduleRefresh(reason: "menu opened", after: 0)
    }

    private func addFooter(_ menu: NSMenu) {
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let login = action("Launch at Login", #selector(toggleLaunchAtLogin), key: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Open Log", #selector(openLog), key: ""))
        menu.addItem(.separator())
        menu.addItem(action("Quit KVM Switcher", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    /// Configured computers first; without a mapping, every known input. Runs on `work`.
    private func switchTargets(_ monitor: Monitor) -> [(label: String, input: InputSource)] {
        let computers = controller.configuration.monitorConfig(for: monitor)?.computers ?? [:]
        if computers.isEmpty {
            return ((try? controller.inputs(of: monitor)) ?? []).map { ($0.description, $0) }
        }
        return computers.sorted { $0.key < $1.key }.compactMap { computer, _ in
            controller.input(forComputer: computer, on: monitor).map { ("\(computer.capitalized) (\($0.name))", $0) }
        }
    }

    private func isCurrent(_ input: InputSource) -> Bool {
        switch reading {
        case .reported(let now), .activeHere(let now?): return now.value == input.value
        default: return false
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    // MARK: Actions

    @objc private func switchInput(_ sender: NSMenuItem) {
        guard let monitor, let target = sender.representedObject as? InputSource, !switching else { return }
        switching = true
        updateTitle()
        work.async { [self] in
            let result = controller.switchInput(of: monitor, to: target)
            DispatchQueue.main.async { [self] in
                switching = false
                if case .failed(let why) = result.outcome { alert("Switch to \(target.name) failed", why) }
                if case .unverified(let why) = result.outcome { log.info("unverified switch: \(why)") }
                refresh(reason: "after switch")
            }
        }
    }

    @objc private func toggleAutoSwitch() {
        autoSwitchEnabled.toggle()
        log.info("auto switch \(autoSwitchEnabled ? "enabled" : "disabled")")
        restartAutoSwitch()
    }

    /// The watcher runs whenever a "kvm" section exists, so the menu can show KVM state.
    /// Switching only happens with Auto switch on, and only on changes after it starts.
    private func restartAutoSwitch() {
        autoSwitcher?.stop()
        autoSwitcher = nil
        watcher?.stop()
        watcher = nil
        guard let kvmConfig else { return }
        let watcher = UsbKvmWatcher(config: kvmConfig)
        if autoSwitchEnabled {
            // DDC is slow; keep it off the watcher's (main) run loop.
            let auto = AutoSwitcher(controller: controller, provider: ForwardingProvider(watcher.provider, queue: work))
            auto.onResult = { [weak self] result in
                DispatchQueue.main.async { self?.scheduleRefresh(reason: "auto switch", after: 0) }
            }
            auto.start()
            autoSwitcher = auto
        }
        watcher.start()
        self.watcher = watcher
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            log.info("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        } catch {
            alert("Could not change Launch at Login", "\(error)")
        }
    }

    @objc private func openSettings() {
        let url = Configuration.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Configuration(thisComputer: "mac").save(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLog() {
        if let url = log.fileURL { NSWorkspace.shared.open(url) }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Re-delivers another provider's state changes on a given queue.
final class ForwardingProvider: KvmStateProvider {
    private let inner: KvmStateProvider
    private let queue: DispatchQueue
    init(_ inner: KvmStateProvider, queue: DispatchQueue) {
        self.inner = inner
        self.queue = queue
    }
    func getState() -> KvmState { inner.getState() }
    func subscribe(_ handler: @escaping (KvmState) -> Void) -> KvmSubscription {
        let queue = queue
        return inner.subscribe { state in queue.async { handler(state) } }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
