import Foundation

/// What this computer can tell about the monitor's current input.
public enum InputReading: Equatable {
    /// VCP 0x60 read back a known input.
    case reported(InputSource)
    /// DDC answers but the read-back value is unusable. With `ddcOnlyOnActiveInput`,
    /// an answer at all means this computer's input is on screen (the associated input).
    case activeHere(InputSource?)
    /// DDC answers with a value that matches no known input and no quirk explains it.
    case unrecognized(UInt16)
    /// DDC null reply: the monitor is on another input (for `ddcOnlyOnActiveInput` monitors).
    case notActiveHere
    case failed(DDCError)

    public var summary: String {
        switch self {
        case .reported(let input): return input.name
        case .activeHere(let input?): return "\(input.name) (this computer; inferred from DDC answering)"
        case .activeHere(nil): return "this computer's input (DDC answers; read-back unreliable)"
        case .unrecognized(let raw): return String(format: "unknown (monitor reported 0x%02X)", raw)
        case .notActiveHere: return "another computer's input (monitor not serving DDC here)"
        case .failed(let error): return "unreadable: \(error)"
        }
    }
}

public struct SwitchResult {
    public enum Outcome: Equatable {
        case verified(String)
        case alreadyActive
        case unverified(String)
        case failed(String)
        case busy
    }

    public let monitor: Monitor
    public let requested: InputSource
    public let before: InputReading
    public let outcome: Outcome
    public let attempts: Int

    public var succeeded: Bool {
        switch outcome {
        case .verified, .alreadyActive: return true
        default: return false
        }
    }
}

/// Input naming, switching, verification and retry policy on top of a raw backend.
public final class InputController {
    public let backend: MonitorBackend
    public var configuration: Configuration
    public var settleDelay: TimeInterval = 1.5
    public var maxAttempts = 3
    public var settlePolls = 8
    public var settlePollInterval: TimeInterval = 0.5

    private let log: Log
    private let sleep: (TimeInterval) -> Void
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    public init(backend: MonitorBackend, configuration: Configuration, log: Log = .shared,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.backend = backend
        self.configuration = configuration
        self.log = log
        self.sleep = sleep
    }

    // MARK: Naming

    private func quirks(_ monitor: Monitor) -> Quirks {
        configuration.monitorConfig(for: monitor)?.quirks ?? Quirks()
    }

    /// Known inputs: configured values first, else what the capabilities string advertises.
    public func inputs(of monitor: Monitor) throws -> [InputSource] {
        if let configured = configuration.monitorConfig(for: monitor)?.inputs, !configured.isEmpty {
            return try configured.map { name, text in
                guard let value = parseVCPValue(text) else { throw ConfigError.badValue(input: name, value: text) }
                return InputSource(name: name, value: value)
            }.sorted { $0.value < $1.value }
        }
        guard let caps = try? backend.capabilities(of: monitor) else { return [] }
        return caps.advertisedInputValues.map(InputSource.mccs)
    }

    /// Accepts an input name ("DP-1", case-insensitive), a computer name ("windows"),
    /// or a raw value ("0x08").
    public func resolve(_ text: String, on monitor: Monitor) throws -> InputSource? {
        let known = try inputs(of: monitor)
        if let byName = known.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return byName }
        if let byComputer = input(forComputer: text, on: monitor) { return byComputer }
        guard let value = parseVCPValue(text) else { return nil }
        return known.first { $0.value == value } ?? InputSource.mccs(value)
    }

    public func input(forComputer computer: String, on monitor: Monitor) -> InputSource? {
        guard let computers = configuration.monitorConfig(for: monitor)?.computers,
              let name = computers.first(where: { $0.key.caseInsensitiveCompare(computer) == .orderedSame })?.value
        else { return nil }
        return (try? inputs(of: monitor))?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func thisComputerInput(on monitor: Monitor) -> InputSource? {
        configuration.thisComputer.flatMap { input(forComputer: $0, on: monitor) }
    }

    // MARK: Reading

    public func currentInput(of monitor: Monitor) -> InputReading {
        let q = quirks(monitor)
        do {
            let (raw, _) = try backend.readInputSource(of: monitor)
            log.debug(String(format: "read VCP 0x60 raw=0x%02X monitor=%@", raw, monitor.name))
            if q.inputReadbackUnreliable != true, let known = try? inputs(of: monitor),
               let match = known.first(where: { $0.value == raw }) {
                return .reported(match)
            }
            if q.ddcOnlyOnActiveInput == true || q.inputReadbackUnreliable == true {
                return .activeHere(q.ddcOnlyOnActiveInput == true ? thisComputerInput(on: monitor) : nil)
            }
            return .unrecognized(raw)
        } catch DDCError.nullReply {
            log.debug("read VCP 0x60: null reply monitor=\(monitor.name)")
            return q.ddcOnlyOnActiveInput == true ? .notActiveHere : .failed(.nullReply)
        } catch let error as DDCError {
            return .failed(error)
        } catch {
            return .failed(.io("\(error)"))
        }
    }

    // MARK: Switching

    public func switchInput(of monitor: Monitor, to target: InputSource) -> SwitchResult {
        guard begin(monitor.id) else {
            log.info("switch ignored: already switching monitor=\(monitor.name)")
            return SwitchResult(monitor: monitor, requested: target, before: .failed(.io("busy")), outcome: .busy, attempts: 0)
        }
        defer { end(monitor.id) }

        let q = quirks(monitor)
        let before = currentInput(of: monitor)
        log.info("requested input=\(target) monitor=\(monitor.name) current=\(before.summary)")

        if isOn(target, before) {
            log.info("already on \(target.name); not sending")
            return SwitchResult(monitor: monitor, requested: target, before: before, outcome: .alreadyActive, attempts: 0)
        }

        var lastObservation = before.summary
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            log.info(String(format: "sending VCP 0x60 = 0x%02X (attempt %d/%d)", target.value, attempt, maxAttempts))
            do {
                try backend.writeInputSource(target.value, to: monitor)
                log.debug("write acknowledged by I2C bus")
            } catch {
                lastObservation = "write failed: \(error)"
                log.error(lastObservation)
                continue
            }
            sleep(settleDelay)

            let after = settledInput(of: monitor)
            lastObservation = after.summary
            switch after {
            case .reported(let now) where now.value == target.value:
                return finish(monitor, target, before, attempt, .verified("monitor reports \(now.name)"))
            case .notActiveHere where before == .notActiveHere:
                return finish(monitor, target, before, attempt, .failed(
                    "monitor is showing another input and ignores DDC from this computer; switch from the computer currently on screen"))
            case .notActiveHere where target != thisComputerInput(on: monitor):
                return finish(monitor, target, before, attempt, .verified("monitor left this computer's input (DDC went silent, as expected for this monitor)"))
            case .activeHere where q.ddcOnlyOnActiveInput == true, .reported:
                log.info("verification: monitor still on \(after.summary); retrying")
            case .activeHere:
                return finish(monitor, target, before, attempt, .unverified("command sent; monitor input read-back is unreliable"))
            case .unrecognized, .failed:
                if q.inputReadbackUnreliable == true || attempt == maxAttempts {
                    return finish(monitor, target, before, attempt, .unverified("command sent, but monitor state after switch is \(after.summary)"))
                }
            case .notActiveHere:
                return finish(monitor, target, before, attempt, .unverified("DDC went silent after switching to this computer's own input"))
            }
        }
        return finish(monitor, target, before, attempt, .failed("monitor did not report the requested input after \(attempt) attempts; last state: \(lastObservation)"))
    }

    /// Mid-switch, monitors can return unparseable bytes (the 34D901 sends all zeros)
    /// before settling into a real answer or a null reply. Poll through that instead
    /// of treating it as the final state; never resend while it lasts.
    private func settledInput(of monitor: Monitor) -> InputReading {
        var reading = currentInput(of: monitor)
        var polls = 0
        while case .failed(let error) = reading, error != .nullReply, polls < settlePolls {
            log.debug("verification: unreadable while settling (\(error)); polling again")
            sleep(settlePollInterval)
            reading = currentInput(of: monitor)
            polls += 1
        }
        return reading
    }

    private func isOn(_ target: InputSource, _ reading: InputReading) -> Bool {
        switch reading {
        case .reported(let now): return now.value == target.value
        case .activeHere(let here?): return here.value == target.value
        default: return false
        }
    }

    private func finish(_ monitor: Monitor, _ target: InputSource, _ before: InputReading, _ attempts: Int,
                        _ outcome: SwitchResult.Outcome) -> SwitchResult {
        switch outcome {
        case .verified(let how): log.info("verified input=\(target.name): \(how)")
        case .unverified(let why): log.info("unverified input=\(target.name): \(why)")
        case .failed(let why): log.error("switch to \(target.name) failed: \(why)")
        default: break
        }
        return SwitchResult(monitor: monitor, requested: target, before: before, outcome: outcome, attempts: attempts)
    }

    private func begin(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(id).inserted
    }

    private func end(_ id: String) {
        lock.lock(); inFlight.remove(id); lock.unlock()
    }
}
