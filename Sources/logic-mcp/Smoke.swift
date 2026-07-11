import AppKit
import ArgumentParser
import Foundation
import LogicMCPCore
import MCP

/// Drive the AX mixer tools against REAL Logic and print results. Uses an InMemoryWire (the AX
/// tools ignore it) so it needs no CoreMIDI port and can run alongside `serve`. Never activates
/// Logic. Mutates and RESTORES vox's volume/pan/mute and one plugin param (net-zero, best effort).
struct Smoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke", abstract: "Drive the AX mixer tools against real Logic (net-zero).")

    @Option(name: .long, help: "Track to exercise.") var track = "vox"

    func run() async throws {
        let front0 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let provider = try SystemAXProvider()
        let (daemonEnd, _) = InMemoryWire.pair()
        let daemon = await Daemon(wire: daemonEnd, axProvider: provider)
        let reg = ToolRegistry()
        await daemon.registerAllTools(in: reg)

        @discardableResult
        func call(_ name: String, _ args: [String: Value] = [:]) async -> String {
            let r = await reg.call(name: name, arguments: args)
            let text = r.content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
            let a = args.isEmpty ? "" : " " + args.map { "\($0)=\($1)" }.joined(separator: " ")
            print("→ \(name)\(a)\n    \(text)\((r.isError ?? false) ? "   [isError]" : "")")
            return text
        }
        func header(_ s: String) { print("\n=== \(s) ===") }

        header("1. refresh_state (full mixer read via AX)")
        await call("refresh_state")

        header("2. get_track \(track) — capture original")
        let before = await call("get_track", ["name": .string(track)])
        func field(_ json: String, _ key: String) -> String? {
            guard let r = json.range(of: "\"\(key)\":") else { return nil }
            let rest = json[r.upperBound...].prefix(40)
            return rest.split(whereSeparator: { ",}".contains($0) }).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let origDB = field(before, "volumeDB")
        let origPan = field(before, "pan")
        let origMute = field(before, "mute")
        print("    captured: volumeDB=\(origDB ?? "?") pan=\(origPan ?? "?") mute=\(origMute ?? "?")")

        header("3. set_volume db:-6  (expect ~-6.0, source ax)")
        await call("set_volume", ["track": .string(track), "db": .double(-6)])
        header("4. set_volume delta:+2  (expect ~-4.0)")
        await call("set_volume", ["track": .string(track), "delta": .double(2)])

        header("5. set_pan position:-30  (expect -30, source ax)")
        await call("set_pan", ["track": .string(track), "position": .int(-30)])

        header("6. set_mute on/off  (idempotent re-call)")
        await call("set_mute", ["track": .string(track), "on": .bool(true)])
        await call("set_mute", ["track": .string(track), "on": .bool(true)])   // idempotent
        await call("set_mute", ["track": .string(track), "on": .bool(false)])

        header("7. set_send  (EXPECT structured 'not available via AX' error)")
        await call("set_send", ["track": .string(track), "bus": .string("Aux 1"), "level": .int(90)])

        header("8. get_plugin_params slot 0  ×2  (same track/params both times?)")
        let p0a = await call("get_plugin_params", ["track": .string(track), "slot": .int(0)])
        let p0b = await call("get_plugin_params", ["track": .string(track), "slot": .int(0)])
        print("    stable across 2 reads: \(p0a == p0b)")

        header("9. RESIDUAL RISK — wrong-SLOT plugin: get_plugin_params slot 1 (should DIFFER from slot 0)")
        let p1 = await call("get_plugin_params", ["track": .string(track), "slot": .int(1)])
        print("    slot0 == slot1 (BUG if true): \(p0a == p1)")

        header("10. set_plugin_param slot 0 — nudge a param, then we do NOT restore (report only)")
        await call("set_plugin_param", ["track": .string(track), "slot": .int(0),
                                        "param": .string("Gain"), "value": .double(0.5)])

        // ---- RESTORE vox to captured state (best effort) ----
        header("RESTORE")
        if let d = origDB, d != "null", let db = Double(d) {
            await call("set_volume", ["track": .string(track), "db": .double(db)])
        }
        if let p = origPan, p != "null", let pan = Int(p) {
            await call("set_pan", ["track": .string(track), "position": .int(pan)])
        }
        if origMute == "true" { await call("set_mute", ["track": .string(track), "on": .bool(true)]) }

        let front1 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("\n=== FOCUS CHECK ===\n    frontmost before=\(front0)  after=\(front1)  (Logic must NOT appear here)")
    }
}
