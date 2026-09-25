import Foundation
import KVMCore
import MacDDC

let usage = """
usage: kvmctl [-v] [--monitor N] <command>

  monitor list                 discovered external monitors and DDC status
  monitor caps                 MCCS capabilities string and advertised inputs
  monitor input list           inputs known for the monitor (config, else capabilities)
  monitor input get            current input as seen from this computer
  monitor input set <INPUT>    switch; INPUT = name (DP-1), computer (windows), or raw (0x08)
  monitor input send <VALUE>   write VCP 0x60 once, no verification (for finding input values)
  kvm watch [--auto]           print KVM state changes from USB presence; --auto also switches
  config path                  print the config file location
  config init                  write a starter config for the first monitor

  -v            debug logging (raw I2C bytes)
  --monitor N   monitor index from `monitor list` (default 0)
"""

var args = Array(CommandLine.arguments.dropFirst())
let log = Log.shared
if let i = args.firstIndex(of: "-v") { log.verbose = true; args.remove(at: i) }
var monitorIndex = 0
if let i = args.firstIndex(of: "--monitor"), i + 1 < args.count, let n = Int(args[i + 1]) {
    monitorIndex = n
    args.removeSubrange(i...(i + 1))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let configuration: Configuration
do { configuration = try Configuration.load() } catch { fail("config: \(Configuration.defaultURL.path): \(error)") }
let backend = MacDDCBackend()
let controller = InputController(backend: backend, configuration: configuration)

func selectedMonitor() -> Monitor {
    let monitors = (try? backend.listMonitors()) ?? []
    guard !monitors.isEmpty else {
        fail("No external monitor with a DDC channel found.\nDDC/CI is not available: check the cable, and that DDC/CI is enabled in the monitor's menu.")
    }
    guard monitorIndex < monitors.count else { fail("no monitor \(monitorIndex); \(monitors.count) found") }
    return monitors[monitorIndex]
}

switch args.joined(separator: " ") {
case "monitor list":
    let monitors = (try? backend.listMonitors()) ?? []
    if monitors.isEmpty { print("No external monitors found.") }
    for (i, m) in monitors.enumerated() {
        let reading = controller.currentInput(of: m)
        let ddc: String
        switch reading {
        case .failed(let error): ddc = "not responding (\(error))"
        case .notActiveHere: ddc = "supported (monitor currently on another input)"
        default: ddc = "supported"
        }
        print("""
        Monitor \(i)
          Name:       \(m.name)
          Maker:      \(m.manufacturer ?? "?")
          ID:         \(m.id)
          Connection: \(m.connection ?? "?")
          DDC:        \(ddc)
          Configured: \(configuration.monitorConfig(for: m) != nil ? "yes" : "no")
        """)
    }

case "monitor caps":
    let m = selectedMonitor()
    do {
        let caps = try backend.capabilities(of: m)
        print("Model:       \(caps.model ?? "?")")
        print("MCCS:        \(caps.mccsVersion ?? "?")")
        print("VCP 0x60:    \(caps.advertisedInputValues.map { InputSource.mccs($0).description }.joined(separator: ", "))")
        print("Raw:         \(caps.raw)")
    } catch {
        fail("Could not read capabilities: \(error)")
    }

case "monitor input list":
    let m = selectedMonitor()
    let inputs: [InputSource]
    do { inputs = try controller.inputs(of: m) } catch { fail("\(error)") }
    let source = configuration.monitorConfig(for: m)?.inputs?.isEmpty == false ? "config" : "capabilities (MCCS names; may not match this monitor)"
    print("Inputs for \(m.name), from \(source):")
    for input in inputs {
        let owners = (configuration.monitorConfig(for: m)?.computers ?? [:])
            .filter { $0.value.caseInsensitiveCompare(input.name) == .orderedSame }.keys.sorted()
        print("  \(input)\(owners.isEmpty ? "" : "  <- " + owners.joined(separator: ", "))")
    }

case "monitor input get":
    let m = selectedMonitor()
    let reading = controller.currentInput(of: m)
    print("Current input: \(reading.summary)")
    if case .failed = reading { exit(1) }

case let command where command.hasPrefix("monitor input set "):
    let m = selectedMonitor()
    let text = String(command.dropFirst("monitor input set ".count))
    guard let target = (try? controller.resolve(text, on: m)) ?? nil else { fail("unknown input \"\(text)\"; see `kvmctl monitor input list`") }
    let result = controller.switchInput(of: m, to: target)
    print("""

    Switching monitor input:
      Monitor: \(m.name)
      Current: \(result.before.summary)
      Target:  \(target)

    Result:
    """)
    switch result.outcome {
    case .verified(let how): print("  success (\(how))")
    case .alreadyActive: print("  success (already on \(target.name); nothing sent)")
    case .unverified(let why): print("  unverified: \(why)")
    case .failed(let why): print("  failed: \(why)")
    case .busy: print("  failed: another switch is in progress")
    }
    exit(result.succeeded ? 0 : 1)

case "kvm watch", "kvm watch --auto":
    guard let kvm = configuration.kvm else { fail("no \"kvm\" section in \(Configuration.defaultURL.path)") }
    setvbuf(stdout, nil, _IONBF, 0) // long-running: show lines immediately, even when piped
    let watcher = UsbKvmWatcher(config: kvm)
    let auto = args.last == "--auto" ? AutoSwitcher(controller: controller, provider: watcher.provider) : nil
    let subscription = watcher.provider.subscribe { state in
        if auto == nil { print("KVM -> \(state.activeComputer ?? "unknown")") }
    }
    auto?.start()
    watcher.start()
    print("Watching \(kvm.usbDevices.count) USB device(s); KVM currently -> \(watcher.provider.getState().activeComputer ?? "unknown"). Ctrl+C to stop.")
    withExtendedLifetime((subscription, auto, watcher)) { RunLoop.main.run() }

case let command where command.hasPrefix("monitor input send "):
    let m = selectedMonitor()
    let text = String(command.dropFirst("monitor input send ".count))
    guard let value = parseVCPValue(text) else { fail("invalid value \"\(text)\"; use hex like 0x06") }
    do {
        try backend.writeInputSource(value, to: m)
        print(String(format: "Sent VCP 0x60 = 0x%02X to %@ (not verified)", value, m.name))
    } catch {
        fail("\(error)")
    }

case "config path":
    print(Configuration.defaultURL.path)

case "config init":
    guard !FileManager.default.fileExists(atPath: Configuration.defaultURL.path) else {
        fail("config already exists: \(Configuration.defaultURL.path)")
    }
    let m = selectedMonitor()
    let caps = try? backend.capabilities(of: m)
    let inputs = Dictionary(uniqueKeysWithValues: (caps?.advertisedInputValues ?? []).map {
        (InputSource.mccs($0).name, String(format: "0x%02X", $0))
    })
    let starter = Configuration(thisComputer: "mac", monitors: [
        MonitorConfig(id: m.id, name: m.name, inputs: inputs, computers: [:], quirks: Quirks()),
    ])
    do { try starter.save() } catch { fail("\(error)") }
    print("Wrote \(Configuration.defaultURL.path)")
    print("Inputs are the monitor's advertised MCCS values; edit them if the monitor ignores those, then fill in \"computers\".")

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
