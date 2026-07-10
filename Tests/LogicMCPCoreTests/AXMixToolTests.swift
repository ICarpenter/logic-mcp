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
                              children: [FakeAXNode(role: "AXWindow", children: [area])]))
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
                               children: [FakeAXNode(role: "AXWindow", children: [area])]))
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
                               children: [FakeAXNode(role: "AXWindow", children: [area])]))
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
}
