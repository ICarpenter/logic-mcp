import ArgumentParser
import Foundation
import LogicMCPCore

/// Diagnostic: the MCU wire carries only a 14-bit raw fader position, never dB, so
/// `FaderCurve` has to interpolate between anchors. This subcommand measures those
/// anchors instead of guessing them: touch a fader, move it to a known raw value, and
/// Logic writes "Volume" / "-9.0 dB" onto the LCD of the touched strip. Sweeping the
/// range and parsing that text yields the real curve, printed as a paste-ready Swift literal.
///
/// This is how the current `FaderCurve.anchors` were produced. Findings worth keeping:
/// Logic snaps every requested raw onto its own grid (8192 echoes 8178), saturates at
/// raw 14845 = +6.0 dB, and reports -oo up to raw 7. The sweep list below intentionally
/// probes past saturation (15360, 16383) so that ceiling shows up in the output.
///
/// Mutates one fader, then restores it. Point it at a scratch project.
struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnostic: does Logic report fader dB on the LCD? Then sweep the curve.")

    @Option(name: .long, help: "Channel strip (0-7) to move.")
    var channel: Int = 0

    @Option(name: .long, help: "Comma-separated raw fader positions to sample during the sweep.")
    var raws: String = "1,1024,2560,4096,6144,8192,10240,11264,12288,12443,13312,14336,15360,16383"

    @Option(name: .long, help: "Milliseconds to let the LCD settle after each move.")
    var settleMs: Int = 300

    @Flag(name: .long, help: "Run only the discovery steps; skip the sweep.")
    var discover = false

    func run() async throws {
        guard (0..<8).contains(channel) else { throw CalibrateError.badChannel }
        let wire = try CoreMIDIWire()
        defer { wire.tearDown() }
        let session = MCUSession(wire: wire)
        await session.start()

        FileHandle.standardError.write(Data("waiting for Logic on '\(wire.portName)'…\n".utf8))
        guard let original = await waitForFader(session) else { throw CalibrateError.noFader }
        print("channel \(channel) rests at raw \(original) "
            + "(our curve calls that \(FaderCurve.dB(fromRaw: original).map { "\($0) dB" } ?? "-inf"))\n")

        let rig = FaderRig(wire: wire, session: session,
                           channel: channel, settle: .milliseconds(settleMs))

        print("=== discovery: where, if anywhere, does Logic print the dB? ===")
        await rig.dump("at rest")
        await rig.pressAndDump(.nameValue, "after NAME/VALUE toggle")
        await rig.touch(true)
        await rig.move(to: 8192)
        await rig.dump("touched + moved to 8192")
        await rig.touch(false)
        await rig.dump("released")
        await rig.pressAndDump(.nameValue, "after NAME/VALUE toggle back")

        if !discover {
            print("\n=== sweep: raw -> what Logic echoes, and what Logic displays ===")
            let samples = raws.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            var measured: [(raw: Int, db: Double?)] = []
            await rig.touch(true)
            for raw in samples {
                await rig.move(to: raw)
                let echoed = await session.surface.faderRaw[channel]
                let shown = await rig.valueText()
                let db = Self.parseDB(shown)
                let ours = FaderCurve.dB(fromRaw: echoed).map { String(format: "%.1f", $0) } ?? "-inf"
                let cell = { (s: String) in s.padding(toLength: 8, withPad: " ", startingAt: 0) }
                print("raw \(cell(String(raw)))-> echo \(cell(String(echoed)))"
                    + "| logic \(cell(shown))| ours \(cell(ours))dB")
                measured.append((echoed, db))
            }
            await rig.touch(false)
            Self.emitAnchors(measured)
        }

        print("\nrestoring channel \(channel) to raw \(original)…")
        await rig.touch(true)
        await rig.move(to: original)
        await rig.touch(false)
        let final = await session.surface.faderRaw[channel]
        print(final == original
            ? "restored (raw \(final))."
            : "WARNING: wanted raw \(original), Logic settled on \(final).")
    }

    /// Logic writes "-59.5 dB" across TWO 7-char cells, so reading one cell truncates it.
    static func parseDB(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.contains("oo") || cleaned.contains("∞") { return nil }   // -oo dB
        return Double(cleaned.replacingOccurrences(of: "+", with: ""))
    }

    /// Anchors must be strictly increasing in BOTH columns for the interpolator, so
    /// drop any sample whose echoed raw or dB did not advance (Logic snaps requests to
    /// its own grid, and saturates at the top — several requests map to one position).
    static func emitAnchors(_ measured: [(raw: Int, db: Double?)]) {
        print("\n=== proposed FaderCurve.anchors (measured from Logic) ===")
        var kept: [(Int, Double)] = []
        for sample in measured {
            guard let db = sample.db, sample.raw > 0 else { continue }
            if let last = kept.last, sample.raw <= last.0 || db <= last.1 { continue }
            kept.append((sample.raw, db))
        }
        print("    static let anchors: [(raw: Int, db: Double)] = [")
        for (raw, db) in kept {
            print(String(format: "        (%d, %.1f),", raw, db))
        }
        print("    ]")
        if let top = kept.last {
            print("// NOTE: Logic saturates at raw \(top.0) = \(String(format: "%.1f", top.1)) dB; "
                + "requests above that echo back \(top.0).")
        }
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

/// Drives one fader directly on the wire. `MCUSession` only exposes `moveFader`,
/// which releases touch before we get to read the LCD — and Logic may only show the
/// value *while* the fader is touched, which is exactly what we are here to find out.
private struct FaderRig {
    let wire: MCUWire
    let session: MCUSession
    let channel: Int
    let settle: Duration

    func touch(_ down: Bool) async {
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: down)))
        await session.settle(settle)
    }

    func move(to raw: Int) async {
        await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: channel, value: raw)))
        await session.settle(settle)
    }

    func pressAndDump(_ button: MCUButton, _ label: String) async {
        await session.press(button)
        await session.settle(settle)
        await dump(label)
    }

    /// The touched fader's value spans this cell and the next one.
    func valueText() async -> String {
        let surface = await session.surface
        let here = surface.lcdCell(line: 1, channel: channel)
        let next = channel < 7 ? surface.lcdCell(line: 1, channel: channel + 1) : ""
        return (here + next).trimmingCharacters(in: .whitespaces)
    }

    func dump(_ label: String) async {
        let surface = await session.surface
        print("\(label.padding(toLength: 28, withPad: " ", startingAt: 0)) "
            + "top='\(surface.lcdTop.prefix(56))'")
        print("\(String(repeating: " ", count: 29))bot='\(surface.lcdBottom.prefix(56))'")
    }
}

enum CalibrateError: Error, CustomStringConvertible {
    case badChannel, noFader
    var description: String {
        switch self {
        case .badChannel: "channel must be 0...7"
        case .noFader:
            "Logic never echoed a fader position — is `serve` still running (same virtual port), "
                + "or is the control surface unbound?"
        }
    }
}
