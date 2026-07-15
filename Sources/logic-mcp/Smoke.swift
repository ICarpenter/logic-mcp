import AppKit
import ArgumentParser
import Foundation
import LogicMCPCore
import MCP

/// Drive the AX mixer tools against REAL Logic and print results. Uses an InMemoryWire (the AX
/// tools ignore it) so it needs no CoreMIDI port and can run alongside `serve`. Never activates
/// Logic. Mutates and RESTORES vox's volume/pan/mute and one plugin param (net-zero, best effort).
///
/// `--structure` instead drives the STRUCTURAL tools (create_track/set_output/insert_plugin/
/// undo_structural) against a scratch track, net-zero by construction — see `runStructural`'s
/// undo-loop cleanup. `delete_track` is DISABLED (Fixtures/ax/selection.txt: AX cannot change
/// Logic's track selection, so pressing a strip then `Track ▸ Delete Track` would delete
/// whatever track the user last selected, not the requested one) — the smoke calls it once to
/// confirm it still cleanly refuses, but never depends on it for cleanup.
/// Cleanup is entirely via `undo_structural` (Edit ▸ Undo), the only working removal path.
struct Smoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke", abstract: "Drive the AX tools against real Logic (net-zero).")

    @Option(name: .long, help: "Track to exercise.") var track = "vox"
    @Flag(name: .long, help: "Run the structural smoke (create_track → set_output → insert_plugin → undo_structural×N to unwind → net-zero check; delete_track is called only to report its disabled response) instead of the mixer smoke.")
    var structure = false

    func run() async throws {
        if structure {
            try await runStructural()
        } else {
            try await runMixer()
        }
    }

    private func runMixer() async throws {
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

    // MARK: - Structural smoke

    /// Net-zero structural smoke: create a scratch track, route it, insert a plugin on it, then
    /// unwind ALL of it via repeated `undo_structural` calls (Edit ▸ Undo is the only working
    /// removal path — `delete_track` is DISABLED, see the type doc comment above). `create_track`
    /// has NO `name` argument (rename is deferred — AX text edits never commit, see
    /// `RenameTrackTool`), so the scratch track is whatever Logic names it (e.g. "Audio 1") and
    /// every step below resolves it by name from the PREVIOUS step's own confirmation rather than
    /// assuming one.
    ///
    /// Every "confirm" is a fresh `refresh_state` re-read (never trusted from a single tool's own
    /// JSON alone — matches this codebase's settle-poll philosophy: AX updates land
    /// asynchronously, so a tool's self-report and ground truth can momentarily disagree). The
    /// undo loop at the end is ALSO the safety net: it keeps calling `Edit ▸ Undo` and re-snapshotting
    /// until every track absent from the step-1 snapshot is gone (or an attempt cap is hit),
    /// regardless of which numbered step above failed — that loop, not the step-by-step narrative,
    /// is what actually guarantees no stray "Audio N" track survives a half-failed run. There is no
    /// checkpoint step (checkpoint is deferred — Logic's Save/Alternatives are disabled) and no
    /// rename step (deferred).
    private func runStructural() async throws {
        let front0 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let provider = try SystemAXProvider()
        let (daemonEnd, _) = InMemoryWire.pair()
        let daemon = await Daemon(wire: daemonEnd, axProvider: provider)
        let reg = ToolRegistry()
        await daemon.registerAllTools(in: reg)

        @discardableResult
        func call(_ name: String, _ args: [String: Value] = [:]) async -> (text: String, isError: Bool) {
            let r = await reg.call(name: name, arguments: args)
            let text = r.content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
            let a = args.isEmpty ? "" : " " + args.map { "\($0)=\($1)" }.joined(separator: " ")
            let err = r.isError ?? false
            print("→ \(name)\(a)\n    \(text)\(err ? "   [isError]" : "")")
            return (text, err)
        }
        func header(_ s: String) { print("\n=== \(s) ===") }

        var allPass = true
        func checkpoint(_ ok: Bool, _ label: String) {
            print("    \(ok ? "PASS" : "FAIL"): \(label)")
            if !ok { allPass = false }
        }

        // Pull one top-level string field out of a tool's JSON object response — same
        // no-JSON-dependency approach as runMixer's `field` helper above, specialized to strings
        // (every field this smoke reads — track/output/plugin/selected/deleted — is a string).
        func stringField(_ json: String, _ key: String) -> String? {
            guard let r = json.range(of: "\"\(key)\":\"") else { return nil }
            let after = json[r.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { return nil }
            return String(after[..<end])
        }
        // `refresh_state`'s payload is a `tracks` ARRAY of objects that each carry a `name` field —
        // pull out every one, in order.
        func trackNames(_ json: String) -> [String] {
            var names: [String] = []
            var rest = Substring(json)
            while let r = rest.range(of: "\"name\":\"") {
                let after = rest[r.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { break }
                names.append(String(after[..<end]))
                rest = after[end...]
            }
            return names
        }
        func snapshotNames() async -> [String] { trackNames(await call("refresh_state").text) }

        header("1. refresh_state — snapshot before")
        let names0 = await snapshotNames()
        print("    \(names0.count) tracks: \(names0)")

        header("2. create_track kind:audio")
        let createResp = await call("create_track", ["kind": .string("audio")])
        var newTrack = stringField(createResp.text, "track")
        // Defensive cross-check independent of create_track's own self-report: diff a fresh
        // refresh_state against the step-1 snapshot. This diff — not the "track" field above — is
        // what the undo-loop cleanup at the end keys off, so it must stand on its own even if the
        // tool's JSON were malformed or its own confirmation timed out.
        let namesAfterCreate = await snapshotNames()
        let diffCreated = namesAfterCreate.filter { !names0.contains($0) }
        if newTrack == nil { newTrack = diffCreated.first }
        checkpoint(newTrack != nil && !createResp.isError,
                   "new strip appeared (tool ok=\(!createResp.isError), diff-detected=\(diffCreated))")
        if diffCreated.count > 1 {
            print("    WARNING: more than one new track detected: \(diffCreated) — undo-loop cleanup will attempt to unwind ALL of them")
        }

        if let scratch = newTrack {
            print("    scratch track: \(scratch)")

            header("3. set_output track:\(scratch) dest:'Bus 3'")
            let outResp = await call("set_output", ["track": .string(scratch), "dest": .string("Bus 3")])
            checkpoint(!outResp.isError && stringField(outResp.text, "output")?.caseInsensitiveCompare("Bus 3") == .orderedSame,
                       "output is Bus 3")

            header("4. insert_plugin track:\(scratch) name:'Channel EQ'")
            let pluginResp = await call("insert_plugin", ["track": .string(scratch), "name": .string("Channel EQ")])
            checkpoint(!pluginResp.isError && stringField(pluginResp.text, "plugin")?.caseInsensitiveCompare("Channel EQ") == .orderedSame,
                       "Channel EQ present on strip")
        } else {
            print("    SKIPPING set_output/insert_plugin — no new track to act on")
        }

        // delete_track is known-limitation/disabled (Fixtures/ax/selection.txt: AX cannot change
        // Logic's track selection). Call it ONLY to confirm its structured response against real
        // Logic — never depend on it for cleanup or net-zero below.
        if let scratch = newTrack {
            header("5. delete_track name:\(scratch)  (REPORT ONLY — expect structured 'not available via AX' error; delete_track is DISABLED)")
            let delResp = await call("delete_track", ["name": .string(scratch)])
            checkpoint(delResp.isError && delResp.text.contains("not available"),
                       "delete_track correctly refused to delete (disabled for wrong-track safety)")
        }

        header("6. undo_structural × N — unwind create_track/set_output/insert_plugin (Edit ▸ Undo is the only working removal path now that delete_track is disabled)")
        if newTrack != nil {
            var names = await snapshotNames()
            var leftover = names.filter { !names0.contains($0) }
            var attempts = 0
            let maxAttempts = 6   // generous headroom above the 3 edits actually made (create/output/insert)
            while !leftover.isEmpty && attempts < maxAttempts {
                attempts += 1
                await call("undo_structural")
                names = await snapshotNames()
                leftover = names.filter { !names0.contains($0) }
            }
            checkpoint(leftover.isEmpty, "all new track(s) unwound via undo_structural after \(attempts) undo(s)\(leftover.isEmpty ? "" : " — still present: \(leftover)")")
        } else {
            print("    SKIPPED — no new track from step 2 to unwind")
        }

        header("8. refresh_state — confirm net-zero")
        let namesFinal = await snapshotNames()
        let netZero = namesFinal.sorted() == names0.sorted()
        checkpoint(netZero, "final track list matches step-1 snapshot")
        if !netZero {
            print("    before: \(names0)\n    after:  \(namesFinal)")
            print("\n########################################################")
            print("### MANUAL CLEANUP MAY BE REQUIRED IN LOGIC — track list did not return to its step-1 snapshot")
            print("########################################################")
        }

        header("9. focus check")
        let front1 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        checkpoint(front1 == front0, "frontmost app unchanged (before=\(front0) after=\(front1))")
        if front1.localizedCaseInsensitiveContains("logic") {
            print("    !!! WARNING: Logic appears frontmost — no-focus invariant violated !!!")
            allPass = false
        }

        print("\n=== STRUCTURAL SMOKE RESULT: \(allPass ? "PASS" : "FAIL") ===")
        if !allPass { throw ExitCode.failure }
    }
}
