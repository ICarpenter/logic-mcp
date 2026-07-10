import ArgumentParser
import Foundation
import LogicMCPCore

/// Diagnostic: discovers how Logic's mixer window actually responds to BANK± and
/// CHANNEL±. Prints the 8 LCD name cells after each press so the offset semantics
/// can be read off directly. Not part of the MCP surface.
///
/// Needs a project with **at least 17 channel strips**, and a strip count that is
/// not a multiple of 8 — otherwise the clamped last bank coincides with a stride
/// boundary and the two candidate `bankLeft` semantics are indistinguishable.
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnostic: report Logic's BANK±/CHANNEL± mixer-window semantics.")

    @Option(name: .long, help: "Milliseconds to wait for the LCD to settle after each press.")
    var settleMs: Int = 250

    @Option(name: .long, help: "Milliseconds to idle after connecting, so any transient banner expires.")
    var warmupMs: Int = 2000

    @Option(name: .long, help: "Seconds to wait for Logic's handshake before giving up.")
    var connectTimeoutSec: Int = 90

    func run() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)

        // Tap the event stream BEFORE start(), so the handshake is observed.
        // `surface.connected` is set by hostConnectionReply *or* any .lcd, so an
        // LCD alone does not prove Logic is receiving what we send. Only
        // hostConnectionReply proves the daemon → Logic direction is alive.
        let tally = EventTally()
        let events = await session.events()
        let collector = Task {
            for await event in events { await tally.record(event) }
        }
        defer { collector.cancel() }

        await session.start()

        FileHandle.standardError.write(Data("waiting for Logic on '\(wire.portName)'…\n".utf8))
        guard await waitForInbound(session) else { throw ProbeError.silent }
        // Pressing an assignment button (PAN etc.) replaces the name row with a
        // mode banner, which would make every later LCD comparison read as
        // "unchanged". Press nothing; just let any existing banner expire.
        try? await Task.sleep(for: .milliseconds(warmupMs))

        let probe = Prober(session: session, settle: .milliseconds(settleMs))

        print("=== 0. inbound traffic ===")
        let counts = await tally.counts
        print("events: \(counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")

        print("\n=== 0b. raw LCD as found (is the top row track names?) ===")
        let surface = await session.surface
        print("top:    '\(surface.lcdTop)'")
        print("bottom: '\(surface.lcdBottom)'")

        // Logic never sends hostConnectionReply (its handshake is lenient), so the
        // only way to prove the daemon → Logic direction is to press something and
        // watch for the echo it must produce. CYCLE is ideal: Logic always mirrors
        // its LED, and pressing it twice leaves the project as we found it.
        print("\n=== 0c. outbound liveness: does Logic act on what we send? ===")
        let before = await tally.ledCount(.cycle)
        await session.press(.cycle)
        try? await Task.sleep(for: .milliseconds(1500))
        let alive = await tally.ledCount(.cycle) > before
        await session.press(.cycle)   // restore the original cycle state
        try? await Task.sleep(for: .milliseconds(500))
        print(alive
            ? "-> CYCLE LED echoed: Logic acts on our presses. Results below are meaningful."
            : "-> NO CYCLE echo: Logic ignores our presses. Every [NO CHANGE] below is meaningless.")
        guard alive else { throw ProbeError.notListening }

        print("\n=== 1. walk right from the far-left bank ===")
        await probe.bankFullyLeft()
        await probe.dump("offset 0")
        var windows = 1
        while windows < 16, await probe.press(.bankRight, "bankRight #\(windows)") {
            windows += 1
        }
        print("-> \(windows) distinct bank windows; now parked on the LAST bank")

        print("\n=== 2. does CHANNEL± scroll the mixer by exactly 1? (at last bank) ===")
        _ = await probe.press(.channelLeft, "channelLeft")
        _ = await probe.press(.channelLeft, "channelLeft")
        _ = await probe.press(.channelRight, "channelRight")

        print("\n=== 3. bankLeft OFF the clamped last bank — offset-based or stride-aligned? ===")
        await probe.bankFullyRight()
        await probe.dump("last bank (re-parked)")
        _ = await probe.press(.bankLeft, "bankLeft #1")
        _ = await probe.press(.bankLeft, "bankLeft #2")

        print("\n=== 4. CHANNEL± at offset 0, then bankRight from a non-aligned offset ===")
        await probe.bankFullyLeft()
        await probe.dump("offset 0")
        _ = await probe.press(.channelRight, "channelRight")
        _ = await probe.press(.channelRight, "channelRight")
        _ = await probe.press(.bankRight, "bankRight from scrolled offset")

        print("\n=== 6. does CHANNEL+ stop at the same right edge (N-8) as bankRight? ===")
        await probe.bankFullyRight()
        await probe.dump("terminal (bank)")
        _ = await probe.press(.channelRight, "channelRight @terminal — expect NO CHANGE")

        print("\n=== 7. measure the clamp distance d by channel-stepping ===")
        await probe.bankFullyRight()
        _ = await probe.press(.bankLeft, "bankLeft -> penultimate stride bank")
        var steps = 0
        while steps < 9, await probe.press(.channelRight, "channelRight #\(steps + 1)") {
            steps += 1
        }
        print("-> d = \(steps) channel steps from the penultimate stride bank to the right edge")
        print("   (if the final window above equals the terminal window, N = 8*(B-2) + d + 8)")

        print("\n=== 5. select LEDs currently lit (for the select-echo fallback) ===")
        let leds = await session.surface.leds
        let lit = (0..<8).filter { leds[.select(channel: $0)] == .on }
        print("select LED on channels: \(lit.isEmpty ? "none" : lit.map(String.init).joined(separator: ", "))")

        await probe.bankFullyLeft()
        print("\nrestored to offset 0.")
    }

    /// Waits until Logic is transmitting at all. This proves only the Logic → daemon
    /// direction; `surface.connected` is set by any inbound `.lcd`, and Logic happily
    /// streams to a surface whose input it is no longer bound to.
    private func waitForInbound(_ session: MCUSession) async -> Bool {
        for _ in 0..<(connectTimeoutSec * 4) {
            if await session.surface.connected { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}

private struct Prober {
    let session: MCUSession
    let settle: Duration

    func cells() async -> [String] {
        let surface = await session.surface
        return (0..<8).map {
            surface.lcdCell(line: 0, channel: $0).trimmingCharacters(in: .whitespaces)
        }
    }

    func render(_ cells: [String]) -> String {
        cells.map { $0.isEmpty ? "·" : $0 }
            .map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }
            .joined(separator: "|")
    }

    func dump(_ label: String, changed: Bool? = nil) async {
        let flag = switch changed {
        case .some(true): " [changed]"
        case .some(false): " [NO CHANGE]"
        case .none: ""
        }
        print("\(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(render(await cells()))\(flag)")
    }

    /// The whole display. Change detection must not look at the top row alone —
    /// a V-Pot assignment banner pins it while the value row underneath still moves.
    private func display() async -> String {
        let surface = await session.surface
        return surface.lcdTop + surface.lcdBottom
    }

    /// Presses `button`, waits for the LCD to settle, and reports whether it changed.
    @discardableResult
    func press(_ button: MCUButton, _ label: String) async -> Bool {
        let before = await display()
        await session.press(button)
        await session.settle(settle)
        let changed = await display() != before
        await dump(label, changed: changed)
        return changed
    }

    func bankFullyLeft() async {
        await pressUntilStill(.bankLeft)
    }

    func bankFullyRight() async {
        await pressUntilStill(.bankRight)
    }

    private func pressUntilStill(_ button: MCUButton) async {
        for _ in 0..<32 {
            let before = await display()
            await session.press(button)
            await session.settle(settle)
            if await display() == before { return }
        }
    }
}

/// Counts inbound MCU events by kind, so the probe can prove which direction of
/// the link is alive rather than inferring it from the display.
private actor EventTally {
    private(set) var counts: [String: Int] = [:]
    private var ledCounts: [MCUButton: Int] = [:]

    func record(_ event: MCUEvent) {
        let kind: String = switch event {
        case .deviceQuery: "deviceQuery"
        case .hostConnectionReply: "hostConnectionReply"
        case .lcd: "lcd"
        case .faderEcho: "faderEcho"
        case .led: "led"
        case .vpotRing: "vpotRing"
        case .timecodeDigit: "timecodeDigit"
        case .meter: "meter"
        }
        counts[kind, default: 0] += 1
        if case .led(let button, _) = event { ledCounts[button, default: 0] += 1 }
    }

    func ledCount(_ button: MCUButton) -> Int { ledCounts[button, default: 0] }
}

enum ProbeError: Error, CustomStringConvertible {
    case silent, notListening
    var description: String {
        switch self {
        case .silent:
            "Logic sent nothing — is Logic running, and is the MCP `serve` process stopped? "
                + "(both create the same virtual port)"
        case .notListening:
            "Logic transmits to us but ignores our presses: its control surface is bound to a stale "
                + "port, or has no channel strips mapped. In Logic, open Control Surfaces ▸ Setup…, "
                + "delete the Mackie Control, and rescan."
        }
    }
}
