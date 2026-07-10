import ArgumentParser
import Foundation
import LogicMCPCore

/// Diagnostic: Logic writes exact parameter values onto the surface LCD — the same channel
/// that `calibrate` reads fader dB from. Before `set_volume`/`set_pan` can return Logic's
/// own numbers instead of their own guesses, three things have to be established:
///
///   1. What FORMAT does Logic use for pan? (at rest the bottom row shows `0 0 0 ...`)
///   2. Is the fader's "Volume / -9.0 dB" text TRANSIENT? It lands on the track-name cells,
///      and `MixerNavigator.enumerateTracks` reads names from those cells. If it never
///      reverts, a `set_volume` would poison the next `refresh_state`.
///   3. What happens on channel 7, where a 2-cell value display has no cell 8 to spill into?
///
/// Mutates one fader and one pan, then restores both. Point it at a scratch project.
struct LCDProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lcdprobe",
        abstract: "Diagnostic: how Logic prints volume/pan values on the LCD, and for how long.")

    @Option(name: .long, help: "Channel strip (0-7) to poke.")
    var channel: Int = 0

    @Option(name: .long, help: "Milliseconds to let the LCD settle after each command.")
    var settleMs: Int = 300

    @Option(name: .long, help: "value | assign | align | restore | toggle | setpan")
    var mode: String = "value"

    @Option(name: .long, help: "setpan: how many bankRight presses after banking fully left.")
    var bankPresses: Int = 2

    @Option(name: .long, help: "setpan: target pan, -64…63.")
    var position: Int = -47

    @Flag(name: .long, help: "setpan: settle between the hard-left sweep and the tick-up.")
    var settleBetween = false

    func run() async throws {
        guard (0..<8).contains(channel) else { throw CalibrateError.badChannel }
        if mode == "assign" { return try await runAssign() }
        if mode == "align" { return try await runAlign() }
        if mode == "restore" { return try await runRestore() }
        if mode == "toggle" { return try await runToggle() }
        if mode == "setpan" { return try await runSetPan() }
        if mode == "vpotcycle" { return try await runVPotCycle() }
        if mode == "twice" { return try await runTwice() }
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        await session.start()

        FileHandle.standardError.write(Data("waiting for Logic on '\(wire.portName)'…\n".utf8))
        guard let originalRaw = await waitForFader(session) else { throw CalibrateError.noFader }

        let settle = Duration.milliseconds(settleMs)
        func dump(_ label: String) async {
            let surface = await session.surface
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0))")
            print("   top='\(surface.lcdTop)'")
            print("   bot='\(surface.lcdBottom)'")
        }
        func cell(_ line: Int, _ ch: Int) async -> String {
            await session.surface.lcdCell(line: line, channel: ch).trimmingCharacters(in: .whitespaces)
        }

        await dump("0. at rest (bottom row = pan values?)")
        let originalPanText = await cell(1, channel)
        print("   -> channel \(channel) pan cell reads '\(originalPanText)'\n")

        // ---- 1. Is the fader value display transient? ----
        print("=== 1. fader value display: format, and does it revert? ===")
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: true)))
        await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: channel, value: 8192)))
        await session.settle(settle)
        await dump("t=0 (touched, moved to 8192)")
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: false)))
        for seconds in [1, 2, 3, 5] {
            try? await Task.sleep(for: .seconds(1))
            await dump("t=\(seconds)s after release")
        }

        print("\nrestoring fader to raw \(originalRaw)…")
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: true)))
        await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: channel, value: originalRaw)))
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: false)))
        await session.settle(settle)

        // ---- 2. Pan display format across the range ----
        print("\n=== 2. pan value display, swept across the range ===")
        await session.press(.assignPan)
        await session.settle(settle)
        for target in [-64, -30, -1, 0, 1, 30, 63] {
            await session.turnVPot(channel: channel, ticks: -127)      // sweep hard left
            await session.settle(settle)
            await session.turnVPot(channel: channel, ticks: target + 64)
            await session.settle(settle)
            let text = await cell(1, channel)
            let top = await cell(0, channel)
            print("pan \(String(target).padding(toLength: 5, withPad: " ", startingAt: 0))"
                + "-> bottom='\(text)'  top='\(top)'")
        }
        // Does the pan cell persist, or revert like the fader banner might?
        try? await Task.sleep(for: .seconds(3))
        print("after 3s idle, pan cell reads '\(await cell(1, channel))'")

        // ---- 3. Channel 7 edge case: a 2-cell display with no cell 8 ----
        if channel != 7 {
            print("\n=== 3. channel 7: where does a 2-cell value display land? ===")
            // Channel 7 is the rightmost strip of the current bank — quite possibly a master
            // or output fader. Capture its resting position FIRST so we can put it back.
            let original7 = await session.surface.faderRaw[7]
            guard original7 >= 0 else {
                print("SKIPPED: no fader echo for channel 7, cannot restore it safely.")
                return
            }
            await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 7, touched: true)))
            await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: 7, value: 8192)))
            await session.settle(settle)
            await dump("channel 7 touched + moved")
            print("   cell(0,6)='\(await cell(0, 6))' cell(0,7)='\(await cell(0, 7))'")
            print("   cell(1,6)='\(await cell(1, 6))' cell(1,7)='\(await cell(1, 7))'")
            await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: 7, value: original7)))
            await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 7, touched: false)))
            await session.settle(settle)
            let restored7 = await session.surface.faderRaw[7]
            print("   channel 7 restored to raw \(restored7)"
                + (restored7 == original7 ? "" : " (WANTED \(original7) — CHECK IT)"))
        }

        print("\nrestoring pan on channel \(channel) to '\(originalPanText)'…")
        if let originalPan = Int(originalPanText) {
            await session.turnVPot(channel: channel, ticks: -127)
            await session.settle(settle)
            await session.turnVPot(channel: channel, ticks: originalPan + 64)
            await session.settle(settle)
            print("pan cell now reads '\(await cell(1, channel))'")
        } else {
            print("WARNING: could not parse original pan '\(originalPanText)' — restore it by hand.")
        }
    }

    /// Does the V-Pot assignment view (which `set_pan` triggers via `.assignPan`) ever put the
    /// track-name row back? `MixerNavigator` reads names from that row.
    private func runAssign() async throws {
        let (wire, session) = try await connect()
        defer { wire.tearDown() }
        let settle = Duration.milliseconds(settleMs)
        func top() async -> String { await session.surface.lcdTop }

        print("before assignPan:  '\(await top())'")
        await session.press(.assignPan)
        await session.settle(settle)
        print("after  assignPan:  '\(await top())'")
        for seconds in [1, 2, 4, 7] {
            try? await Task.sleep(for: .seconds(seconds == 1 ? 1 : seconds == 2 ? 1 : seconds == 4 ? 2 : 3))
            print("t=\(seconds)s:            '\(await top())'")
        }
        print("\n-- now turn a V-Pot, then watch again --")
        await session.turnVPot(channel: channel, ticks: 3)
        await session.settle(settle)
        print("after vpot turn:   '\(await top())'")
        for seconds in [1, 3, 6] {
            try? await Task.sleep(for: .seconds(seconds == 1 ? 1 : seconds == 3 ? 2 : 3))
            print("t=\(seconds)s:            '\(await top())'")
        }
        await session.turnVPot(channel: channel, ticks: -3)   // restore pan
        await session.settle(settle)

        print("\n-- does a bank round-trip force the name row back? --")
        _ = await session.press(.bankRight); await session.settle(settle)
        _ = await session.press(.bankLeft); await session.settle(settle)
        print("after bankRight+bankLeft: '\(await top())'")
    }

    /// Where does the 14-char value field land for a mid-bank channel vs the last one?
    private func runAlign() async throws {
        let (wire, session) = try await connect()
        defer { wire.tearDown() }
        let settle = Duration.milliseconds(settleMs)
        for ch in [3, 6, 7] {
            let original = await session.surface.faderRaw[ch]
            guard original >= 0 else { print("ch \(ch): no fader echo, skipped"); continue }
            await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: ch, touched: true)))
            await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: ch, value: 8192)))
            await session.settle(settle)
            let surface = await session.surface
            let cells = (0..<8).map { surface.lcdCell(line: 1, channel: $0) }
            let pair = min(ch, 6)
            let joined = (cells[pair] + cells[pair + 1]).trimmingCharacters(in: .whitespaces)
            print("ch \(ch): cells[\(pair)]+[\(pair+1)] = '\(joined)'   raw bottom='\(surface.lcdBottom)'")
            await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: ch, value: original)))
            await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: ch, touched: false)))
            await session.settle(settle)
            try? await Task.sleep(for: .seconds(3))   // let the banner expire before the next one
        }
    }

    /// `.assignPan` pins the top row to `Pan | - | - ...` and nothing observed so far puts the
    /// track names back. Try the plausible buttons one at a time and report which one does.
    private func runRestore() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForConnected(session) else { throw CalibrateError.noFader }
        let settle = Duration.milliseconds(settleMs)

        func looksLikeNames(_ top: String) -> Bool {
            !top.hasPrefix("Pan") && !top.hasPrefix("Volume") && !top.trimmingCharacters(in: .whitespaces).isEmpty
        }
        print("start:                     '\(await session.surface.lcdTop)'")

        // Enter the modal state FIRST. A fresh process handshake makes Logic redraw the names,
        // so probing "restore" straight after connecting measures nothing.
        await session.press(.assignPan)
        await session.settle(settle)
        let modal = await session.surface.lcdTop
        print("after assignPan:           '\(modal)'\(looksLikeNames(modal) ? "  (NOT modal?!)" : "  <== modal")")
        guard !looksLikeNames(modal) else {
            print("\n-> assignPan did not pin the row this time; nothing to restore.")
            return
        }

        let candidates: [(MCUButton, String)] = [
            (.nameValue, "nameValue (0x34)"),
            (.assignPan, "assignPan again (toggle?)"),
            (.assignTrack, "assignTrack (0x28)"),
            (.select(channel: 0), "select ch0"),
        ]
        for (button, label) in candidates {
            await session.press(button)
            await session.settle(settle)
            let top = await session.surface.lcdTop
            if looksLikeNames(top) {
                print("\(label.padding(toLength: 26, withPad: " ", startingAt: 0)) '\(top)'  <== NAMES BACK")
                print("\n-> '\(label)' restores the track-name row.")
                return
            }
            print("\(label.padding(toLength: 26, withPad: " ", startingAt: 0)) '\(top)'")
        }

        // A fader touch paints a "Volume" banner that we KNOW expires after ~2s. Does the row
        // it reverts to carry names, or the pinned assignment view?
        print("\n-- fader touch, then wait out the ~2s banner --")
        await session.press(.assignPan)   // ensure we are back in the modal state
        await session.settle(settle)
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: true)))
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: false)))
        await session.settle(settle)
        print("right after touch:         '\(await session.surface.lcdTop)'")
        try? await Task.sleep(for: .seconds(3))
        let after = await session.surface.lcdTop
        print("3s after touch:            '\(after)'\(looksLikeNames(after) ? "  <== NAMES BACK" : "")")
        if !looksLikeNames(after) { print("\n-> nothing tried here restores the name row.") }
    }

    /// `set_pan` presses `.assignPan`. Depending on Logic's PERSISTENT Name/Value toggle, that
    /// either paints a banner that expires, or pins the top row to `Pan | - | - ...` forever —
    /// and `MixerNavigator` reads track names from that row. Characterise both toggle states.
    private func runToggle() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForConnected(session) else { throw CalibrateError.noFader }
        let settle = Duration.milliseconds(settleMs)
        func top() async -> String { await session.surface.lcdTop }

        for pass in 1...2 {
            print("=== pass \(pass) (toggle state \(pass == 1 ? "as found" : "flipped")) ===")
            print("  before assignPan: '\(await top())'")
            await session.press(.assignPan)
            await session.settle(settle)
            print("  after  assignPan: '\(await top())'")
            for wait in [2, 5] {
                try? await Task.sleep(for: .seconds(wait == 2 ? 2 : 3))
                print("  t=\(wait)s:            '\(await top())'")
            }
            // Does banking redraw the names from here?
            await session.press(.bankRight)
            await session.settle(settle)
            print("  after bankRight:  '\(await top())'")
            await session.press(.bankLeft)
            await session.settle(settle)
            print("  after bankLeft:   '\(await top())'")

            if pass == 1 {
                print("\n  -- pressing nameValue to flip the toggle --\n")
                await session.press(.nameValue)
                await session.settle(settle)
                print("  after nameValue:  '\(await top())'\n")
            }
        }
        print("\nNOTE: this leaves Logic's Name/Value toggle FLIPPED from where it started.")
        print("Press it once more to restore, if the top row is not showing track names.")
        await session.press(.nameValue)
        await session.settle(settle)
        print("final top row: '\(await top())'")
    }

    /// Reproduce EXACTLY what `set_pan` puts on the wire, but with the bottom row (which
    /// carries pan) dumped at every step, and every inbound vpotRing logged. `set_pan`
    /// reports success on a real Logic yet the pan does not move — so either the ticks are
    /// not landing, or they are landing somewhere other than where we think.
    private func runSetPan() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)

        let rings = RingLog()
        let events = await session.events()
        let collector = Task { for await event in events { await rings.record(event) } }
        defer { collector.cancel() }

        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForConnected(session) else { throw CalibrateError.noFader }
        let settle = Duration.milliseconds(settleMs)

        func rows(_ label: String) async {
            let surface = await session.surface
            print("\(label)")
            print("   top='\(surface.lcdTop)'")
            print("   bot='\(surface.lcdBottom)'")
        }

        // Mimic bank(toShow: 16) on a 20-strip project: fully left, then bankRight twice.
        while true {
            let before = await session.surface.lcdTop
            await session.press(.bankLeft)
            await session.settle(settle)
            if await session.surface.lcdTop == before { break }
        }
        for _ in 0..<bankPresses {
            await session.press(.bankRight)
            await session.settle(settle)
        }
        await rows("after banking (channel \(channel) should be the target strip)")

        await session.press(.assignPan)
        await session.settle(settle)
        await rows("after assignPan")

        await rings.reset()
        print("\n-- sweep hard left: turnVPot(\(channel), -127) --")
        await session.turnVPot(channel: channel, ticks: -127)
        if settleBetween { await session.settle(settle) }
        await rows("after sweep")
        print("   vpotRing echoes seen: \(await rings.summary())")

        await rings.reset()
        let ticks = position + 64
        print("\n-- tick up: turnVPot(\(channel), +\(ticks)) --")
        await session.turnVPot(channel: channel, ticks: ticks)
        await session.settle(settle)
        await rows("after tick-up")
        print("   vpotRing echoes seen: \(await rings.summary())")
        let surface = await session.surface
        print("\n   every bottom cell (pan per channel):")
        for i in 0..<8 {
            let mark = i == channel ? "   <== target" : ""
            print("     cell(1,\(i)) = '\(surface.lcdCell(line: 1, channel: i).trimmingCharacters(in: .whitespaces))'\(mark)")
        }
    }

    /// `.assignPan` is NOT idempotent: pressing it while already in per-channel pan cycles
    /// into a single-parameter page for the SELECTED track, where other V-Pots do nothing.
    /// Find the button sequence that returns to per-channel pan, and confirm a V-Pot turn
    /// on a non-zero channel actually produces a ring echo there.
    private func runVPotCycle() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        let rings = RingLog()
        let events = await session.events()
        let collector = Task { for await event in events { await rings.record(event) } }
        defer { collector.cancel() }
        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForConnected(session) else { throw CalibrateError.noFader }
        let settle = Duration.milliseconds(settleMs)

        func show(_ label: String) async {
            let s = await session.surface
            print("\(label.padding(toLength: 30, withPad: " ", startingAt: 0)) bot='\(s.lcdBottom)'")
            print("\(String(repeating: " ", count: 31))top='\(s.lcdTop)'")
        }
        /// Per-channel pan is showing when several channels carry their own value/name.
        func perChannel() async -> Bool {
            let s = await session.surface
            let cells = (0..<8).map { s.lcdCell(line: 1, channel: $0).trimmingCharacters(in: .whitespaces) }
            return cells.filter { $0 != "-" && !$0.isEmpty }.count >= 2
        }

        await show("as found")
        print("   per-channel? \(await perChannel())\n")

        for i in 1...4 {
            await session.press(.assignPan)
            await session.settle(settle)
            await show("assignPan x\(i)")
            print("   per-channel? \(await perChannel())\n")
        }

        await session.press(.nameValue)
        await session.settle(settle)
        await show("nameValue")
        print("   per-channel? \(await perChannel())\n")

        // Once per-channel pan is up, does a turn on the target channel echo a ring?
        if await perChannel() {
            await rings.reset()
            await session.turnVPot(channel: channel, ticks: 3)
            await session.settle(settle)
            await show("turnVPot(ch\(channel), +3)")
            print("   ring echoes: \(await rings.summary())")
            await session.turnVPot(channel: channel, ticks: -3)   // put it back
            await session.settle(settle)
            await show("turnVPot(ch\(channel), -3) restore")
        } else {
            print("still not per-channel; not turning anything.")
        }
    }

    /// `set_pan` works on the first call and reports "no ring echo" on an identical second
    /// call. Surface is already normalized, so nothing should differ. Run the exact sweep
    /// twice, logging every inbound ring, and see what Logic actually does.
    private func runTwice() async throws {
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        let rings = RingLog()
        let events = await session.events()
        let collector = Task { for await event in events { await rings.record(event) } }
        defer { collector.cancel() }
        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForConnected(session) else { throw CalibrateError.noFader }
        let settle = Duration.milliseconds(settleMs)

        // Bank to the target window without touching any assignment button.
        while true {
            let before = await session.surface.lcdTop
            await session.press(.bankLeft)
            await session.settle(settle)
            if await session.surface.lcdTop == before { break }
        }
        for _ in 0..<bankPresses { await session.press(.bankRight); await session.settle(settle) }

        func bot() async -> String { await session.surface.lcdBottom }
        print("start bot='\(await bot())'")

        for pass in 1...3 {
            await rings.reset()
            print("\n=== pass \(pass): turnVPot(\(channel), -127) then +\(position + 64) ===")
            await session.turnVPot(channel: channel, ticks: -127)
            if settleBetween {
                await session.settle(settle)
                print("  after sweep  bot='\(await bot())'  rings=\(await rings.summary())")
                await rings.reset()
            } else {
                print("  (no settle between turns — exactly what set_pan does)")
            }
            await session.turnVPot(channel: channel, ticks: position + 64)
            await session.settle(settle)
            print("  after tickup bot='\(await bot())'  rings=\(await rings.summary())")
            let cell = await session.surface.lcdCell(line: 1, channel: channel).trimmingCharacters(in: .whitespaces)
            print("  pan cell = '\(cell)'")
        }
    }

    private func waitForConnected(_ session: MCUSession) async -> Bool {
        for _ in 0..<80 {
            if await session.surface.connected { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func connect() async throws -> (CoreMIDIWire, MCUSession) {
        let wire = try CoreMIDIWire()
        let session = MCUSession(wire: wire)
        await session.start()
        FileHandle.standardError.write(Data("waiting for Logic…\n".utf8))
        guard await waitForFader(session) != nil else { throw CalibrateError.noFader }
        return (wire, session)
    }

    private func waitForFader(_ session: MCUSession) async -> Int? {
        for _ in 0..<80 {
            let surface = await session.surface
            if surface.connected, surface.faderRaw[channel] >= 0 { return surface.faderRaw[channel] }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}

/// Counts inbound V-Pot ring echoes, so we can tell "Logic ignored our turns" apart from
/// "Logic answered but the pan did not move".
private actor RingLog {
    private var values: [Int: [Int]] = [:]   // channel -> ring values, in order

    func record(_ event: MCUEvent) {
        if case .vpotRing(let channel, let value) = event { values[channel, default: []].append(value) }
    }
    func reset() { values = [:] }
    func summary() -> String {
        guard !values.isEmpty else { return "NONE" }
        return values.sorted { $0.key < $1.key }
            .map { "ch\($0.key): \($0.value.count) echoes \(Array($0.value.prefix(12)))\($0.value.count > 12 ? "…" : "")" }
            .joined(separator: " | ")
    }
}
