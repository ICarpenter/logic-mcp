import XCTest
import MCP
@testable import LogicMCPCore

final class ToolTests: XCTestCase {
    func testPingReturnsOkAndVersion() async throws {
        let registry = ToolRegistry()
        await registry.register(PingTool(version: "0.1.0"))
        let result = await registry.call(name: "ping", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        guard case .text(let json, _, _)? = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("0.1.0"))
    }

    func testUnknownToolIsStructuredError() async throws {
        let registry = ToolRegistry()
        let result = await registry.call(name: "nope", arguments: nil)
        XCTAssertEqual(result.isError, true)
        guard case .text(let json, _, _)? = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(json.contains("\"layer\":\"daemon\""))
    }

    /// The re-homed query tools (`refresh_state`/`get_project_overview`/`get_track`) and the
    /// re-homed `set_mute`/`set_solo`/`set_volume`/`set_pan` now read/write via AX, never the
    /// MCU wire — so the fake AX mixer must mirror `FakeLogic.standardSession()`'s names (same
    /// order) AND carry mute/solo AXSwitch children plus a volume fader + fader-level title
    /// plus a pan slider, or those tools see an empty/wrong shadow model, find no control at
    /// all, or have no dB title to converge on — even though `FakeLogic` (the MCU side) is
    /// fully populated.
    static func axProviderForStandardSession() -> FakeAXProvider {
        // Every track's volume fader starts at raw 173 / 0.0 dB, mirroring FakeLogic's own
        // 12443-raw/0.0dB default so the two (independent) shadow states start in agreement.
        // Pan starts centered (raw 0), matching FakeLogic's own 64-centered default (0 + 64).
        // NUDGE-MODE: models real Logic (AXSetValue moves ±1 toward target); the dB title is
        // recomputed from the resulting unit after every nudge — same shape as
        // AXMixToolTests.stripWithVolumeCurve().
        var volToLevel: [ObjectIdentifier: FakeAXNode] = [:]
        let strips = FakeLogic.standardSession().map { t -> FakeAXNode in
            let level = FakeAXNode(role: "AXStaticText", description: "volume fader level",
                                   title: "volume fader level, 0.0 dB")
            let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173,
                                 settable: true, minValue: 0, maxValue: 233)
            let pan = FakeAXNode(role: "AXSlider", description: "pan", value: 0,
                                 settable: true, minValue: -64, maxValue: 63)
            volToLevel[ObjectIdentifier(vol)] = level
            return FakeAXNode(role: "AXLayoutItem", description: t.name, children: [
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute",
                          stringValue: t.mute ? "on" : "off"),
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo",
                          stringValue: t.solo ? "on" : "off"),
                vol, level, pan,
            ])
        }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: strips)
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        p.nudgeMode = true
        p.onSetNumber = { node, resulting in
            guard let level = volToLevel[ObjectIdentifier(node)] else { return }
            let db = (resulting - 173) * 0.1
            level.title = "volume fader level, \(String(format: "%+.1f", db)) dB"
        }
        return p
    }

    func makeDaemonWithFakeLogic(
        tracks: [FakeLogic.FakeTrack] = FakeLogic.standardSession()
    ) async -> (daemon: Daemon, registry: ToolRegistry, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks)
        let daemon = await Daemon(wire: daemonEnd, axProvider: Self.axProviderForStandardSession())
        await fake.start()
        let registry = ToolRegistry()
        await daemon.registerAllTools(in: registry)
        _ = await daemon.session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        return (daemon, registry, fake)
    }

    /// Decode a tool result's JSON text into a dictionary.
    func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
        guard case .text(let json, _, _)? = result.content.first else { throw ToolFailure(error: "no text", layer: "daemon") }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testGetProjectOverviewListsTracks() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "get_project_overview", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        let tracks = json["tracks"] as! [[String: Any]]
        XCTAssertEqual(tracks.count, 16)
        XCTAssertEqual(tracks[0]["name"] as? String, "Kick")
        _ = fake
    }

    func testGetTrackByName() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "get_track", arguments: ["name": .string("Vocal")])
        let json = try resultJSON(result)
        XCTAssertEqual(json["index"] as? Int, 10)
        _ = fake
    }

    func testGetTrackMissIsStructuredError() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "get_track", arguments: ["name": .string("Trombone")])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "model")
        _ = fake
    }

    func testPlayVerifiedByLED() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "play", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["playing"] as? Bool, true)
        let playing = await fake.isPlaying
        XCTAssertTrue(playing)
    }

    func testRecordRefusesWithoutConfirm() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "record", arguments: [:])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertTrue((json["error"] as! String).contains("confirm"))
        let recording = await fake.isRecording
        XCTAssertFalse(recording)
    }

    func testRecordWithConfirm() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "record", arguments: ["confirm": .bool(true)])
        XCTAssertNotEqual(result.isError, true)
        let recording = await fake.isRecording
        XCTAssertTrue(recording)
    }

    func testStopAfterPlay() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "play", arguments: [:])
        let result = await registry.call(name: "stop", arguments: [:])
        let json = try resultJSON(result)
        XCTAssertEqual(json["playing"] as? Bool, false)
        let playing = await fake.isPlaying
        XCTAssertFalse(playing)
    }

    func testToggleCycle() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()

        // First toggle: not cycling -> cycling. Exercises the `currentlyCycling ? .off : .on`
        // branch where currentlyCycling is false (expects LED .on).
        let firstResult = await registry.call(name: "toggle_cycle", arguments: [:])
        XCTAssertNotEqual(firstResult.isError, true)
        let firstJSON = try resultJSON(firstResult)
        XCTAssertEqual(firstJSON["cycling"] as? Bool, true)
        let cyclingAfterFirst = await fake.cycling
        XCTAssertTrue(cyclingAfterFirst)

        // Second toggle: cycling -> not cycling. Exercises the other branch, where
        // currentlyCycling is true (expects LED .off).
        let secondResult = await registry.call(name: "toggle_cycle", arguments: [:])
        XCTAssertNotEqual(secondResult.isError, true)
        let secondJSON = try resultJSON(secondResult)
        XCTAssertEqual(secondJSON["cycling"] as? Bool, false)
        let cyclingAfterSecond = await fake.cycling
        XCTAssertFalse(cyclingAfterSecond)
    }

    func testSetVolumeAbsolute() async throws {
        // set_volume is AX-based now (see MixTools.axConvergeVolume) — verify against the AX
        // fader-level title (ground truth), not FakeLogic's MCU-side state, which this tool
        // never touches.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, -6.0, accuracy: 0.2)
        XCTAssertEqual(json["source"] as? String, "ax")
        let strip = try await daemon.ax.find("Vocal")
        let controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.volumeDB!, -6.0, accuracy: 0.2)
        _ = fake
    }

    func testSetVolumeDelta() async throws {
        // NOTE: retains `fake` — FakeLogic's packet loop holds only `[weak self]`, and this
        // test drives a real handshake/LCD round-trip via makeDaemonWithFakeLogic(); discarding
        // the tuple's third element lets ARC deallocate FakeLogic once that call returns. See
        // the recurring "FakeLogic [weak self]" gotcha.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_volume",
                                arguments: ["track": .string("Bass"), "db": .double(-3.0)])
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Bass"), "delta": .double(-2.0)])
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, -5.0, accuracy: 0.3)
        _ = fake
    }

    func testSetVolumeRequiresExactlyOneOfDbOrDelta() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let neither = await registry.call(name: "set_volume", arguments: ["track": .string("Bass")])
        XCTAssertEqual(neither.isError, true)
        let both = await registry.call(name: "set_volume", arguments: [
            "track": .string("Bass"), "db": .double(0), "delta": .double(1),
        ])
        XCTAssertEqual(both.isError, true)
        _ = fake
    }

    func testSetVolumeDeltaOnUnobservedTrackReadsFaderFirst() async throws {
        // Delta with no prior volume knowledge: tool must first observe the current dB via
        // the AX fader-level title (axProviderForStandardSession starts every track at 0.0
        // dB, mirroring FakeLogic's own default) and land at -2.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Kick"), "delta": .double(-2.0)])
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, -2.0, accuracy: 0.3)
        _ = fake
    }

    func testSetMuteOnAndIdempotent() async throws {
        // set_mute is AX-based now (see MixTools.setToggleAX) — verify against the AX
        // switch's actual value, not FakeLogic's MCU-side state, which this tool never touches.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_mute",
                                         arguments: ["track": .string("Snare"), "on": .bool(true)])
        let json = try resultJSON(result)
        XCTAssertEqual(json["mute"] as? Bool, true)
        let strip = try await daemon.ax.find("Snare")
        var controls = await daemon.ax.read(strip)
        XCTAssertTrue(controls.mute)
        // Setting the same value again must NOT toggle it back off.
        _ = await registry.call(name: "set_mute",
                                arguments: ["track": .string("Snare"), "on": .bool(true)])
        controls = await daemon.ax.read(strip)
        XCTAssertTrue(controls.mute)
        _ = fake
    }

    func testSetSolo() async throws {
        // set_solo is AX-based now — verify against the AX switch, not FakeLogic's MCU state.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_solo",
                                arguments: ["track": .string("Bass"), "on": .bool(true)])
        let strip = try await daemon.ax.find("Bass")
        let controls = await daemon.ax.read(strip)
        XCTAssertTrue(controls.solo)
        _ = fake
    }

    func testSetPanVerifiedByAX() async throws {
        // set_pan is AX-based now (see MixTools.SetPanTool) — verify against the AX pan
        // slider's raw value, not FakeLogic's MCU-side state, which this tool never touches.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("Keys"), "position": .int(-30)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["pan"] as? Int, -30)
        XCTAssertEqual(json["source"] as? String, "ax")
        let strip = try await daemon.ax.find("Keys")
        let controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.pan, -30)
        _ = fake
    }

    func testGetTrackPanMatchesSetPan() async throws {
        // NOTE: retains `fake` — see the recurring "FakeLogic [weak self]" gotcha
        // documented on testSetVolumeDelta: discarding the tuple's third element lets
        // ARC deallocate FakeLogic once makeDaemonWithFakeLogic() returns, which would
        // kill the mock before the set_pan round-trip completes.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        let setResult = await registry.call(name: "set_pan",
                                            arguments: ["track": .string("Keys"), "position": .int(-30)])
        XCTAssertNotEqual(setResult.isError, true)
        let setJSON = try resultJSON(setResult)
        XCTAssertEqual(setJSON["pan"] as? Int, -30)

        // set_pan is AX-based now — the AX pan slider (not FakeLogic's MCU-side state,
        // which this tool never touches) is the ground truth.
        let strip = try await daemon.ax.find("Keys")
        let controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.pan, -30)

        // get_track must report pan on the same -64…63 public scale as set_pan, not
        // the raw stored 0…127 shadow-model value.
        let getResult = await registry.call(name: "get_track", arguments: ["name": .string("Keys")])
        XCTAssertNotEqual(getResult.isError, true)
        let getJSON = try resultJSON(getResult)
        XCTAssertEqual(getJSON["pan"] as? Int, -30)
        _ = fake
    }

    func testSetAutomationMode() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_automation_mode",
                                         arguments: ["track": .string("Vocal"), "mode": .string("latch")])
        XCTAssertNotEqual(result.isError, true)
        let state = await fake.state
        XCTAssertEqual(state[10].automationMode, "latch")
    }

    func testSetSendReturnsNotAccessibleErrorAndTouchesNoMCUState() async throws {
        // set_send's MCU implementation (.assignSend + blind V-Pot turn + LCD readback) is
        // retired — it could write to whichever track Logic's assignment view happened to be
        // following, not necessarily the one named here (the project's most dangerous bug
        // class; see ax-findings.md §Sends). This replaces testSetSendLevel/testSetSendUnknownBus,
        // which asserted the old MCU behavior (a successful echoed write, and a "no send cell
        // matching 'Bus 9'" layer:"mcu" error) that no longer applies. Retains `fake` — same
        // "FakeLogic [weak self]" gotcha as testSetVolumeDelta: discarding the tuple's third
        // element would let ARC deallocate FakeLogic before the sends[1] assertion below.
        //
        // Seed Vocal's Bus 2 send to a NONZERO value first: `standardSession()` seeds every
        // send at 0, which is also what an untouched send reads as, so asserting `== 0` after
        // the call is tautological — it would pass even if a regression let the old MCU write
        // (level: 90) land on the wrong value, or even the wrong track's send. Seeding nonzero
        // and asserting it is UNCHANGED is a real guard: only a genuine no-op survives it.
        var tracks = FakeLogic.standardSession()
        let seededLevel = 55
        tracks[10].sends[1].level = seededLevel
        let (_, registry, fake) = await makeDaemonWithFakeLogic(tracks: tracks)
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Vocal"), "bus": .string("Bus 2"), "level": .int(90),
        ])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "ax")
        XCTAssertTrue((json["error"] as? String ?? "").contains("not available"))
        // Prove the MCU hazard is actually gone: FakeLogic's send state must be untouched.
        let state = await fake.state
        XCTAssertEqual(state[10].sends[1].level, seededLevel)
    }

    func testSetSendUnknownTrackErrorsBeforeNotAccessible() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Nonexistent"), "bus": .string("Bus 2"), "level": .int(10),
        ])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "ax")   // AXBridge.find() error, not "not available"
        _ = fake
    }

    func testUndoLastRestoresVolume() async throws {
        // set_volume is AX-based now — undo must be verified against the AX fader-level title.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-2.0)])
        let result = await registry.call(name: "undo_last", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        let strip = try await daemon.ax.find("Vocal")
        let controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.volumeDB!, -6.0, accuracy: 0.2)
        _ = fake
    }

    func testUndoLastTwoSpansTools() async throws {
        // set_mute/set_volume are both AX-based now — undo of either must be verified
        // against the AX switch / fader-level title, never FakeLogic's MCU-side state,
        // which neither tool touches.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Kick"), "db": .double(-9.0)])
        _ = await registry.call(name: "undo_last", arguments: ["n": .int(2)])
        let bassStrip = try await daemon.ax.find("Bass")
        let bassControls = await daemon.ax.read(bassStrip)
        XCTAssertFalse(bassControls.mute)                    // mute undone
        let kickStrip = try await daemon.ax.find("Kick")
        let kickControls = await daemon.ax.read(kickStrip)
        XCTAssertEqual(kickControls.volumeDB!, 0.0, accuracy: 0.2)   // volume back to initial 0 dB
        _ = fake
    }

    func testUndoLastNegativeNIsSafe() async throws {
        // set_mute is AX-based now — verify the still-muted state against the AX switch.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        let result = await registry.call(name: "undo_last", arguments: ["n": .int(-1)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual((json["undone"] as! [Any]).count, 0)
        let strip = try await daemon.ax.find("Bass")
        let controls = await daemon.ax.read(strip)
        XCTAssertTrue(controls.mute)   // still muted — nothing was undone
        _ = fake
    }

    func testUndoEmptyJournal() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`) — same
        // "FakeLogic [weak self]" gotcha as the other tests in this file.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "undo_last", arguments: [:])
        let json = try resultJSON(result)
        XCTAssertEqual((json["undone"] as! [Any]).count, 0)
        _ = fake
    }

    // MARK: - JSON numeric coercion
    //
    // JSON has one number type, but the MCP SDK decodes `-12` to `.int(-12)` and
    // `-12.5` to `.double(-12.5)`, and its `intValue`/`doubleValue` accessors match
    // only their own case. These tests pin the behaviour that a caller may write
    // either spelling for any numeric argument.

    func testSetVolumeAcceptsIntegerDbSameAsDouble() async throws {
        // JSON `db: -12` decodes to `.int(-12)`; it must be accepted and converge on the
        // same dB as `db: -12.0`. set_volume is AX-based now — the result carries
        // `volumeDB`, not `volumeRaw`.
        let (_, registryInt, fakeInt) = await makeDaemonWithFakeLogic()
        let intResult = await registryInt.call(name: "set_volume",
                                               arguments: ["track": .string("Vocal"), "db": .int(-12)])
        XCTAssertNotEqual(intResult.isError, true, "integer dB must be accepted, not rejected")
        let intDB = try resultJSON(intResult)["volumeDB"] as? Double

        let (_, registryDouble, fakeDouble) = await makeDaemonWithFakeLogic()
        let doubleResult = await registryDouble.call(name: "set_volume",
                                                     arguments: ["track": .string("Vocal"), "db": .double(-12.0)])
        let doubleDB = try resultJSON(doubleResult)["volumeDB"] as? Double

        XCTAssertNotNil(intDB)
        XCTAssertNotNil(doubleDB)
        XCTAssertEqual(intDB!, doubleDB!, accuracy: 0.01, ".int(-12) and .double(-12.0) must converge the same")
        XCTAssertEqual(intDB!, -12.0, accuracy: 0.2)
        _ = fakeInt
        _ = fakeDouble
    }

    func testSetVolumeAcceptsIntegerDelta() async throws {
        // Kick starts at 0.0 dB (raw 12443); delta `.int(3)` must land at +3.0 dB.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Kick"), "delta": .int(3)])
        XCTAssertNotEqual(result.isError, true, "integer delta must be accepted, not rejected")
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, 3.0, accuracy: 0.3)
        _ = fake
    }

    func testSetVolumeArgErrorsAreDistinguishable() async throws {
        // "neither", "both", and "supplied but not a number" must be three DIFFERENT
        // messages — a caller who passed a bad `db` should not be told they need
        // exactly one of two arguments.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()

        let neither = await registry.call(name: "set_volume", arguments: ["track": .string("Bass")])
        XCTAssertEqual(neither.isError, true)
        let neitherMsg = try resultJSON(neither)["error"] as? String ?? ""

        let both = await registry.call(name: "set_volume", arguments: [
            "track": .string("Bass"), "db": .double(0), "delta": .double(1),
        ])
        XCTAssertEqual(both.isError, true)
        let bothMsg = try resultJSON(both)["error"] as? String ?? ""

        let notANumber = await registry.call(name: "set_volume", arguments: [
            "track": .string("Bass"), "db": .string("loud"),
        ])
        XCTAssertEqual(notANumber.isError, true)
        let notANumberMsg = try resultJSON(notANumber)["error"] as? String ?? ""

        XCTAssertNotEqual(neitherMsg, bothMsg, "neither vs both must differ")
        XCTAssertNotEqual(neitherMsg, notANumberMsg, "neither vs non-numeric must differ")
        XCTAssertNotEqual(bothMsg, notANumberMsg, "both vs non-numeric must differ")
        _ = fake
    }

    func testSetPanAcceptsIntegralDoubleButRejectsFractional() async throws {
        // `position: -30.0` is an integral double and must be accepted; `position: 2.5`
        // is fractional and must be REJECTED, never truncated to 2. set_pan is AX-based
        // now — verify against the AX pan slider, not FakeLogic's MCU-side state, which
        // this tool never touches.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        let ok = await registry.call(name: "set_pan",
                                     arguments: ["track": .string("Keys"), "position": .double(-30.0)])
        XCTAssertNotEqual(ok.isError, true, "integral double position must be accepted")
        let strip = try await daemon.ax.find("Keys")
        var controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.pan, -30)

        let rejected = await registry.call(name: "set_pan",
                                           arguments: ["track": .string("Keys"), "position": .double(2.5)])
        XCTAssertEqual(rejected.isError, true, "fractional position must be rejected, not truncated")
        controls = await daemon.ax.read(strip)
        XCTAssertEqual(controls.pan, -30, "pan must be unchanged after the rejected 2.5")
        _ = fake
    }

    func testSetSendAcceptsIntegralDoubleLevel() async throws {
        // `level: 100.0` decodes to `.double(100.0)`; an integral double must still pass
        // argument validation (layer:"daemon") rather than be rejected as non-numeric — it
        // must reach the (now always-thrown) layer:"ax" not-available error, not bounce off
        // 'level' coercion first. This retains the coercion regression coverage from the old
        // MCU-era test without asserting the retired successful-write behavior.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Vocal"), "bus": .string("Bus 2"), "level": .double(100.0),
        ])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "ax", "integral double level must pass coercion and reach the not-available error, not a 'daemon' argument error")
        _ = fake
    }

    func testUndoLastAcceptsDoubleN() async throws {
        // `n: 2.0` decodes to `.double(2.0)` and must behave like `.int(2)`.
        let (daemon, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Kick"), "db": .double(-9.0)])
        _ = await registry.call(name: "undo_last", arguments: ["n": .double(2.0)])
        let state = await fake.state
        XCTAssertFalse(state[6].mute, "both mutations must be undone when n is a double")
        // set_volume is AX-based now — verify the undone volume against the AX fader-level
        // title, not FakeLogic's MCU-side state, which this tool never touches.
        let kickStrip = try await daemon.ax.find("Kick")
        let kickControls = await daemon.ax.read(kickStrip)
        XCTAssertEqual(kickControls.volumeDB!, 0.0, accuracy: 0.2)
        _ = fake
    }
}
