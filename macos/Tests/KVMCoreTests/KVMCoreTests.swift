import XCTest
@testable import KVMCore

final class DDCFramingTests: XCTestCase {
    func testVCPGetRequestMatchesWire() {
        // Captured from the probe on the real monitor.
        XCTAssertEqual(DDC.vcpGetRequest(code: 0x60), [0x82, 0x01, 0x60, 0xDC])
    }

    func testCapabilitiesRequestMatchesWire() {
        XCTAssertEqual(DDC.capabilitiesRequest(offset: 0x20), [0x83, 0xF3, 0x00, 0x20, 0x6F])
    }

    func testParsesRealBrightnessReply() {
        let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x2E]
        XCTAssertEqual(DDC.parseReply(bytes), .vcp(code: 0x10, current: 100, maximum: 100))
    }

    func testParsesRealNullReply() {
        // What the 34D901 sends the Mac while it shows the PC's input.
        let bytes: [UInt8] = [0x6E, 0x80, 0xBE, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x5F]
        XCTAssertEqual(DDC.parseReply(bytes), .null)
    }

    func testRejectsBadChecksum() {
        let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA5, 0x2E]
        guard case .invalid = DDC.parseReply(bytes) else { return XCTFail("expected invalid") }
    }

    func testUnsupportedResultCode() {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes.append(DDC.xor(0x50, bytes))
        XCTAssertEqual(DDC.parseReply(bytes), .unsupported(code: 0x10))
    }
}

final class CapabilitiesTests: XCTestCase {
    let real = "(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 11 12 0F 10) AA(01 02) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))"

    func testParsesAdvertisedInputs() {
        let caps = Capabilities(parsing: real)
        XCTAssertEqual(caps.advertisedInputValues, [0x11, 0x12, 0x0F, 0x10])
        XCTAssertEqual(caps.mccsVersion, "2.1")
        XCTAssertEqual(caps.vcp[0x14], [0x05, 0x08, 0x0B, 0x0C])
        XCTAssertEqual(caps.vcp[0x10], [])
        XCTAssertNil(caps.model)
    }

    func testParsesVCPValues() {
        XCTAssertEqual(parseVCPValue("0x08"), 8)
        XCTAssertEqual(parseVCPValue("0F"), nil) // bare hex without prefix is ambiguous; decimal only
        XCTAssertEqual(parseVCPValue("0fh"), 15)
        XCTAssertEqual(parseVCPValue("17"), 17)
    }
}

/// Simulates the 34D901: answers DDC only on the active input, returns garbage for
/// VCP 0x60, and drops the first N writes.
final class FakeMonitor: MonitorBackend {
    let monitor = Monitor(id: "fake", name: "Fake", manufacturer: nil, connection: nil, ddcAvailable: true)
    var activeInput: UInt16
    let hereInput: UInt16
    var dropWrites: Int
    var garbageReadback: Bool
    var ddcOnlyOnActive: Bool
    /// Reads that return garbage bytes right after the monitor leaves this input,
    /// before it settles into null replies (seen on the 34D901 after `set windows`).
    var transitionalGarbageReads = 0
    private var pendingGarbage = 0
    private(set) var writes: [UInt16] = []

    init(active: UInt16, here: UInt16, dropWrites: Int = 0, garbageReadback: Bool = true, ddcOnlyOnActive: Bool = true) {
        activeInput = active
        hereInput = here
        self.dropWrites = dropWrites
        self.garbageReadback = garbageReadback
        self.ddcOnlyOnActive = ddcOnlyOnActive
    }

    func listMonitors() throws -> [Monitor] { [monitor] }
    func capabilities(of monitor: Monitor) throws -> Capabilities { Capabilities(parsing: "vcp(60(11 0F))") }

    func readInputSource(of monitor: Monitor) throws -> (current: UInt16, maximum: UInt16) {
        if pendingGarbage > 0 {
            pendingGarbage -= 1
            throw DDCError.invalidReply("invalid(\"bad source 0x00\")")
        }
        if ddcOnlyOnActive && activeInput != hereInput { throw DDCError.nullReply }
        return (garbageReadback ? 0x64 : activeInput, 0x0E)
    }

    func writeInputSource(_ value: UInt16, to monitor: Monitor) throws {
        writes.append(value)
        if ddcOnlyOnActive && activeInput != hereInput { return } // ignored off-input
        if dropWrites > 0 { dropWrites -= 1; return }
        if value != activeInput { pendingGarbage = transitionalGarbageReads }
        activeInput = value
    }
}

final class InputControllerTests: XCTestCase {
    let quirky = Configuration(thisComputer: "mac", monitors: [MonitorConfig(
        id: "fake", inputs: ["HDMI-1": "0x06", "DP-1": "0x08"],
        computers: ["mac": "HDMI-1", "windows": "DP-1"],
        quirks: Quirks(ddcOnlyOnActiveInput: true, inputReadbackUnreliable: true))])

    func controller(_ backend: FakeMonitor, _ config: Configuration) -> InputController {
        let c = InputController(backend: backend, configuration: config, sleep: { _ in })
        return c
    }

    func testSwitchAwayIsVerifiedByDDCGoingSilent() throws {
        let fake = FakeMonitor(active: 0x06, here: 0x06)
        let c = controller(fake, quirky)
        let target = try XCTUnwrap(c.resolve("windows", on: fake.monitor))
        let result = c.switchInput(of: fake.monitor, to: target)
        guard case .verified = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(fake.writes, [0x08])
    }

    func testGarbageWhileMonitorSettlesStillVerifies() throws {
        let fake = FakeMonitor(active: 0x06, here: 0x06)
        fake.transitionalGarbageReads = 2
        let c = controller(fake, quirky)
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("windows", on: fake.monitor)))
        guard case .verified = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(fake.writes, [0x08]) // no resend while the monitor is mid-switch
    }

    func testDroppedWriteIsRetried() throws {
        let fake = FakeMonitor(active: 0x06, here: 0x06, dropWrites: 1)
        let c = controller(fake, quirky)
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("DP-1", on: fake.monitor)))
        guard case .verified = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(result.attempts, 2)
    }

    func testAllWritesDroppedFailsLoudly() throws {
        let fake = FakeMonitor(active: 0x06, here: 0x06, dropWrites: 99)
        let c = controller(fake, quirky)
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("DP-1", on: fake.monitor)))
        guard case .failed = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(fake.writes.count, 3)
    }

    func testAlreadyOnTargetSendsNothing() throws {
        let fake = FakeMonitor(active: 0x06, here: 0x06)
        let c = controller(fake, quirky)
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("mac", on: fake.monitor)))
        XCTAssertEqual(result.outcome, .alreadyActive)
        XCTAssertEqual(fake.writes, [])
    }

    func testCannotPullMonitorBackFromAnotherInput() throws {
        let fake = FakeMonitor(active: 0x08, here: 0x06)
        let c = controller(fake, quirky)
        XCTAssertEqual(c.currentInput(of: fake.monitor), .notActiveHere)
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("mac", on: fake.monitor)))
        guard case .failed(let why) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(why.contains("switch from the computer currently on screen"))
        XCTAssertEqual(fake.writes.count, 1)
    }

    func testWellBehavedMonitorVerifiesByReadback() throws {
        let fake = FakeMonitor(active: 0x11, here: 0x11, garbageReadback: false, ddcOnlyOnActive: false)
        let c = controller(fake, Configuration())
        XCTAssertEqual(c.currentInput(of: fake.monitor), .reported(InputSource(name: "HDMI-1", value: 0x11)))
        let result = c.switchInput(of: fake.monitor, to: try XCTUnwrap(c.resolve("DP-1", on: fake.monitor)))
        XCTAssertEqual(result.outcome, .verified("monitor reports DP-1"))
    }

    func testComputerMappingIsNotAssumed() throws {
        let fake = FakeMonitor(active: 0x11, here: 0x11, garbageReadback: false, ddcOnlyOnActive: false)
        let c = controller(fake, Configuration())
        XCTAssertNil(c.input(forComputer: "windows", on: fake.monitor))
    }

    func testAutoSwitcherMapsKvmStateToInput() {
        let fake = FakeMonitor(active: 0x06, here: 0x06)
        let c = controller(fake, quirky)
        let provider = ManualKvmStateProvider()
        let auto = AutoSwitcher(controller: c, provider: provider)
        auto.start()
        provider.set(activeComputer: "windows")
        XCTAssertEqual(fake.writes, [0x08])
        provider.set(activeComputer: "windows") // unchanged state: no resend
        XCTAssertEqual(fake.writes, [0x08])
    }
}

final class PresenceKvmStateProviderTests: XCTestCase {
    let kvm = KvmDetectionConfig(usbDevices: [UsbDeviceMatch(vendorId: 13782)], presentMeans: "mac", absentMeans: "windows")
    var pending: [() -> Void] = []

    func makeProvider() -> PresenceKvmStateProvider {
        PresenceKvmStateProvider(config: kvm, schedule: { [unowned self] _, work in pending.append(work) })
    }

    func flush() { let work = pending; pending = []; work.forEach { $0() } }

    func testInitialEnumerationSetsStateWithoutNotifying() {
        let p = makeProvider()
        var seen: [String?] = []
        let sub = p.subscribe { seen.append($0.activeComputer) }
        p.deviceAppeared(1, description: "USB2.1 Hub")
        p.deviceAppeared(2, description: "USB3.2 Hub")
        p.initialEnumerationComplete()
        flush()
        XCTAssertEqual(p.getState().activeComputer, "mac")
        XCTAssertEqual(seen, [])
        withExtendedLifetime(sub) {}
    }

    func testAllDevicesGoneMeansOtherComputer() {
        let p = makeProvider()
        var seen: [String?] = []
        let sub = p.subscribe { seen.append($0.activeComputer) }
        p.deviceAppeared(1, description: "hub A")
        p.deviceAppeared(2, description: "hub B")
        p.initialEnumerationComplete()
        p.deviceDisappeared(1, description: "hub A")
        flush()
        XCTAssertEqual(seen, [], "one hub left: still here")
        p.deviceDisappeared(2, description: "hub B")
        flush()
        XCTAssertEqual(seen, ["windows"])
        withExtendedLifetime(sub) {}
    }

    func testReEnumerationFlapIsDebounced() {
        // Observed on return: hubs appear unnamed, vanish, reappear within ~1 s.
        let p = makeProvider()
        var seen: [String?] = []
        let sub = p.subscribe { seen.append($0.activeComputer) }
        p.initialEnumerationComplete() // KVM on the PC at launch
        p.deviceAppeared(10, description: "IOUSBHostDevice")
        p.deviceDisappeared(10, description: "IOUSBHostDevice")
        p.deviceAppeared(11, description: "USB2.1 Hub")
        flush() // only the last scheduled settle acts
        XCTAssertEqual(seen, ["mac"])
        withExtendedLifetime(sub) {}
    }
}

final class AutoSwitcherTests: XCTestCase {
    let quirky = InputControllerTests().quirky

    func testKvmLeavingSendsMonitorToOtherComputer() {
        let fake = FakeMonitor(active: 0x06, here: 0x06)
        let c = InputController(backend: fake, configuration: quirky, sleep: { _ in })
        let results = AutoSwitcher(controller: c, provider: ManualKvmStateProvider()).apply(KvmState(activeComputer: "windows"))
        XCTAssertEqual(fake.writes, [0x08])
        guard case .verified = results.first?.outcome else { return XCTFail("\(results)") }
    }

    func testKvmReturningDoesNotSendWhenMonitorIsAway() {
        let fake = FakeMonitor(active: 0x08, here: 0x06)
        let c = InputController(backend: fake, configuration: quirky, sleep: { _ in })
        let results = AutoSwitcher(controller: c, provider: ManualKvmStateProvider()).apply(KvmState(activeComputer: "mac"))
        XCTAssertEqual(fake.writes, [])
        XCTAssertTrue(results.isEmpty)
    }
}
