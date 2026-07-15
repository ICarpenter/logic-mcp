import XCTest
import MCP
@testable import LogicMCPCore

final class AXMixToolTests: XCTestCase {
    func daemon(_ provider: FakeAXProvider) async -> Daemon {
        await Daemon(wire: InMemoryWire(), axProvider: provider)
    }
    func oneStrip(mute: String = "off") -> FakeAXProvider {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: mute),
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
            FakeAXNode(role: "AXStaticText", description: "volume fader level", title: "volume fader level, 0.0 dB"),
            FakeAXNode(role: "AXSlider", description: "pan", value: 0, settable: true, minValue: -64, maxValue: 63),
            FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true, minValue: 0, maxValue: 233),
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true   // model real Logic: AXSetValue nudges ±1 toward target
        return p
    }

    func testMuteOnPressesAndVerifies() async throws {
        let d = await daemon(oneStrip(mute: "off"))
        _ = try await d.axMixer.syncTracks()
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
        let snap = await d.model.snapshot
        XCTAssertEqual(snap.tracks[0].mute, true)
    }

    /// Models Logic's ASYNCHRONOUS AXSwitch update (real-Logic smoke bug): `AXPress` flips the
    /// switch, but the new value isn't visible on `.value` reads until a few reads later.
    /// `pressLatency = 3` holds the flipped value back for 3 reads. A single-read confirm (the
    /// pre-fix implementation) would see the stale "off" and throw "mute not confirmed"; the
    /// poll in `setToggleAX` must wait it out and succeed.
    func testSetMuteConfirmsThroughPressLatency() async throws {
        let mute = FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off")
        mute.pressLatency = 3
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            mute,
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true
        let d = await daemon(p)
        _ = try await d.axMixer.syncTracks()
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
        let snap = await d.model.snapshot
        XCTAssertEqual(snap.tracks[0].mute, true)
    }

    func testMuteIdempotentWhenAlreadyOn() async throws {
        let d = await daemon(oneStrip(mute: "on"))
        _ = try await d.axMixer.syncTracks()
        // Already on: pressing would turn it OFF, so an idempotent impl must NOT press.
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
    }

    /// A fake volume slider whose fader-level title tracks a monotonic unit→dB curve, so
    /// binary search has something real to converge on.
    // NUDGE-MODE fake: models real Logic (AXSetValue moves ±1 toward target). The dB title is
    // recomputed from the fader unit after every nudge, so the convergence loop has a moving
    // oracle exactly like real Logic. dB = (unit - 173) * 0.1 (173 ≈ 0 dB; matches fixtures).
    func stripWithVolumeCurve() -> FakeAXProvider {
        let level = FakeAXNode(role: "AXStaticText", description: "volume fader level",
                               title: "volume fader level, 0.0 dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173,
                             settable: true, minValue: 0, maxValue: 233)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            vol, level,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                               children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true   // <-- model Logic's ±1-per-set behavior
        p.onSetNumber = { node, resulting in
            guard node === vol else { return }
            let db = (resulting - 173) * 0.1
            level.title = "volume fader level, \(String(format: "%+.1f", db)) dB"
        }
        return p
    }

    func testSetVolumeConvergesToTargetDB() async throws {
        let d = await daemon(stripWithVolumeCurve())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "db": .double(-6.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -6.0, accuracy: 0.11)
        XCTAssertEqual(o["source"], .string("ax"))
    }

    func testSetVolumeDeltaFromCurrent() async throws {
        let d = await daemon(stripWithVolumeCurve())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "delta": .double(-3.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -3.0, accuracy: 0.11)
    }

    /// Same nudge-mode shape as `stripWithVolumeCurve`, but the fader STARTS silent (below
    /// unit 5, where the title has no number — matches real Logic's -∞ region) and only
    /// starts reporting a numeric dB once it climbs above that region. Regression guard for
    /// the bug where `axConvergeVolume` read `db() == nil` on iteration 1 and bailed out
    /// having never nudged the slider.
    func stripSilentVolume() -> FakeAXProvider {
        let level = FakeAXNode(role: "AXStaticText", description: "volume fader level",
                               title: "volume fader level, -∞ dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 0,
                             settable: true, minValue: 0, maxValue: 233)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            vol, level,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                               children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true
        p.onSetNumber = { node, resulting in
            guard node === vol else { return }
            if resulting <= 5 {
                level.title = "volume fader level, -∞ dB"
            } else {
                let db = (resulting - 173) * 0.1
                level.title = "volume fader level, \(String(format: "%+.1f", db)) dB"
            }
        }
        return p
    }

    func testSetVolumeClimbsOutOfSilence() async throws {
        let d = await daemon(stripSilentVolume())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "db": .double(-6.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -6.0, accuracy: 0.11)
        XCTAssertEqual(o["source"], .string("ax"))
    }

    /// A pan slider whose raw `.value` read lags `setValueLatency` reads behind every
    /// `setNumber` — models the THIRD async-read race (real-Logic smoke, `feat/ax-mixer-core`):
    /// `AXUIElementSetAttributeValue` updates a slider's raw value ASYNCHRONOUSLY on real Logic,
    /// so an immediate post-nudge read can return the STALE pre-nudge value, indistinguishable
    /// from "stuck at a boundary" to a single-read stuck-check.
    func stripWithLaggyPan(latency: Int) -> FakeAXProvider {
        let pan = FakeAXNode(role: "AXSlider", description: "pan", value: 0, settable: true,
                             minValue: -64, maxValue: 63, setValueLatency: latency)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            pan,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true
        return p
    }

    /// Regression test: pre-fix, `AXBridge.nudgeToRaw`'s single immediate post-nudge read sees
    /// the stale (unchanged) raw value on iteration 1, concludes the slider is "stuck", and
    /// returns 5 short of the -5 target having never actually moved. Post-fix, the settle-poll
    /// in `AXBridge.settledValue` waits out the lag before trusting "no movement".
    func testSetPanConvergesThroughAsyncValueReadLag() async throws {
        let d = await daemon(stripWithLaggyPan(latency: 2))
        _ = try await d.axMixer.syncTracks()
        let result = try await SetPanTool(daemon: d).invoke(["track": .string("vox"), "position": .int(-5)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["pan"], .int(-5), "convergence must not bail early on a stale post-nudge read")
        XCTAssertEqual(o["source"], .string("ax"))
    }

    /// Same async-value fake, but through `axConvergeVolume`'s raw-value stuck-detection
    /// (`nowRaw == lastRaw`). Only the volume fader's raw `.value` attribute lags —
    /// the dB fader-level TITLE (a separate AX attribute, updated via `onSetNumber`) stays
    /// immediately accurate, exactly matching the real-Logic smoke bug shape.
    func stripWithLaggyVolumeCurve(latency: Int) -> FakeAXProvider {
        let level = FakeAXNode(role: "AXStaticText", description: "volume fader level",
                               title: "volume fader level, 0.0 dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173,
                             settable: true, minValue: 0, maxValue: 233, setValueLatency: latency)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            vol, level,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                               children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])]))
        p.nudgeMode = true
        p.onSetNumber = { node, resulting in
            guard node === vol else { return }
            let db = (resulting - 173) * 0.1
            level.title = "volume fader level, \(String(format: "%+.1f", db)) dB"
        }
        return p
    }

    /// Regression test — real-Logic smoke evidence: `set_volume db:-0.2` converged from -4.1
    /// and bailed at -1.1 dB (~0.9 dB short) because a post-nudge raw-value read came back stale
    /// and looked stuck. Pre-fix here, the same shape: `axConvergeVolume` bails on iteration 1
    /// having barely moved off 0.0 dB. Post-fix, the settle-poll confirms each apparent "stuck"
    /// before trusting it, and convergence reaches the target.
    func testSetVolumeConvergesThroughAsyncValueReadLag() async throws {
        let d = await daemon(stripWithLaggyVolumeCurve(latency: 2))
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "db": .double(-1.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -1.0, accuracy: 0.11,
                       "convergence must not bail early on a stale post-nudge raw-value read")
    }

    func testSetPanWritesAndReadsBack() async throws {
        let d = await daemon(oneStrip())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetPanTool(daemon: d).invoke(["track": .string("vox"), "position": .int(-30)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["pan"], .int(-30))
        XCTAssertEqual(o["source"], .string("ax"))
        let snap = await d.model.snapshot
        XCTAssertEqual(snap.tracks[0].pan, 34)   // -30 + 64
    }

    /// Regression guard: `priorPan`/undo baseline must come from AX, not the shadow model.
    /// Deliberately skips `syncTracks()` — the shadow model is empty, so the old
    /// `daemon.model.snapshot`-derived baseline would have been nil (silently non-undoable)
    /// even though `oneStrip()`'s AX pan slider has a perfectly readable starting value (0).
    func testSetPanUndoBaselineComesFromAXWhenModelUnsynced() async throws {
        let d = await daemon(oneStrip())
        let result = try await SetPanTool(daemon: d).invoke(["track": .string("vox"), "position": .int(-30)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["pan"], .int(-30))
        XCTAssertEqual(o["source"], .string("ax"))
        let mutation = await d.journal.popLast(1).first
        guard let undoArgs = mutation?.undoArguments else {
            return XCTFail("undo baseline was nil — set_pan must read prior value from AX, not the (unsynced, empty) shadow model")
        }
        XCTAssertEqual(undoArgs["track"], "vox")
        XCTAssertEqual(undoArgs["position"], "0")   // oneStrip()'s pan slider starts at AX value 0
    }

    func testSetSendReturnsNotAccessibleError() async throws {
        let d = await daemon(oneStrip())
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await SetSendTool(daemon: d).invoke([
                "track": .string("vox"), "bus": .string("Aux 1"), "level": .int(90)])
            XCTFail("expected a not-accessible ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("not available"))
        }
    }

    func testSetSendUnknownTrackStillErrorsClearly() async throws {
        let d = await daemon(oneStrip())
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await SetSendTool(daemon: d).invoke([
                "track": .string("nope"), "bus": .string("Aux 1"), "level": .int(90)])
            XCTFail("expected a track-not-found ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")   // find() throws layer:"ax" for unknown track
        }
    }
}
