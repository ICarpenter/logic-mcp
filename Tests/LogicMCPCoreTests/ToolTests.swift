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

    func makeDaemonWithFakeLogic() async -> (daemon: Daemon, registry: ToolRegistry, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        let daemon = await Daemon(wire: daemonEnd)
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
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, -6.0, accuracy: 0.2)
        let state = await fake.state
        XCTAssertEqual(state[10].volumeRaw, FaderCurve.raw(fromDB: -6.0))
    }

    func testSetVolumeDelta() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`). FakeLogic's
        // packet loop holds only `[weak self]`; discarding the tuple's third element
        // lets ARC deallocate FakeLogic as soon as this function returns from
        // makeDaemonWithFakeLogic(), which kills the mock mid-test and makes the
        // second set_volume call's fader-echo wait time out. See the recurring
        // "FakeLogic [weak self]" gotcha — same fix as testSetVolumeAbsolute already uses.
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
        // Delta with no prior volume knowledge: tool must first observe the current
        // position (FakeLogic tracks start at 12443 = 0 dB) and land at -2.
        // NOTE: retains `fake` — see testSetVolumeDelta's comment on the [weak self] gotcha;
        // this test also drives a real moveFader round-trip and needs FakeLogic alive for it.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("Kick"), "delta": .double(-2.0)])
        let json = try resultJSON(result)
        XCTAssertEqual(json["volumeDB"] as! Double, -2.0, accuracy: 0.3)
        _ = fake
    }

    func testSetMuteOnAndIdempotent() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_mute",
                                         arguments: ["track": .string("Snare"), "on": .bool(true)])
        let json = try resultJSON(result)
        XCTAssertEqual(json["mute"] as? Bool, true)
        var state = await fake.state
        XCTAssertTrue(state[1].mute)
        // Setting the same value again must NOT toggle it back off.
        _ = await registry.call(name: "set_mute",
                                arguments: ["track": .string("Snare"), "on": .bool(true)])
        state = await fake.state
        XCTAssertTrue(state[1].mute)
    }

    func testSetSolo() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_solo",
                                arguments: ["track": .string("Bass"), "on": .bool(true)])
        let state = await fake.state
        XCTAssertTrue(state[6].solo)
    }

    func testSetPanVerifiedByRing() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("Keys"), "position": .int(-30)])
        XCTAssertNotEqual(result.isError, true)
        let state = await fake.state
        XCTAssertEqual(state[9].pan, 34)   // 64 + (-30)
    }

    func testGetTrackPanMatchesSetPan() async throws {
        // NOTE: retains `fake` — see the recurring "FakeLogic [weak self]" gotcha
        // documented on testSetVolumeDelta: discarding the tuple's third element lets
        // ARC deallocate FakeLogic once makeDaemonWithFakeLogic() returns, which would
        // kill the mock before the set_pan round-trip completes.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let setResult = await registry.call(name: "set_pan",
                                            arguments: ["track": .string("Keys"), "position": .int(-30)])
        XCTAssertNotEqual(setResult.isError, true)
        let setJSON = try resultJSON(setResult)
        XCTAssertEqual(setJSON["pan"] as? Int, -30)

        // Model/FakeLogic ground truth is stored 0…127 (64 = center) — 34 is correct here.
        let state = await fake.state
        XCTAssertEqual(state[9].pan, 34)

        // get_track must report pan on the same -64…63 public scale as set_pan, not
        // the raw stored 0…127 value.
        let getResult = await registry.call(name: "get_track", arguments: ["name": .string("Keys")])
        XCTAssertNotEqual(getResult.isError, true)
        let getJSON = try resultJSON(getResult)
        XCTAssertEqual(getJSON["pan"] as? Int, -30)
    }

    func testSetAutomationMode() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_automation_mode",
                                         arguments: ["track": .string("Vocal"), "mode": .string("latch")])
        XCTAssertNotEqual(result.isError, true)
        let state = await fake.state
        XCTAssertEqual(state[10].automationMode, "latch")
    }

    func testSetSendLevel() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Vocal"), "bus": .string("Bus 2"), "level": .int(90),
        ])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["level"] as? Int, 90)
        let state = await fake.state
        XCTAssertEqual(state[10].sends[1].level, 90)
    }

    func testSetSendUnknownBus() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`). Same
        // "FakeLogic [weak self]" gotcha as testSetVolumeDelta: discarding the tuple's
        // third element lets ARC deallocate FakeLogic once makeDaemonWithFakeLogic()
        // returns, which would kill the mock's send page mid-test and make "Bus 9"
        // absent for the wrong reason (dead mock, empty LCD) rather than because it's
        // genuinely not one of the two configured sends.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Vocal"), "bus": .string("Bus 9"), "level": .int(10),
        ])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "mcu")
        _ = fake
    }

    func testGetPluginParamsPagesThroughAll() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`). Same
        // "FakeLogic [weak self]" gotcha as testSetVolumeDelta/testSetSendUnknownBus:
        // discarding the tuple's third element lets ARC deallocate FakeLogic once
        // makeDaemonWithFakeLogic() returns, which would kill the mock mid-paging and
        // make get_plugin_params falsely "succeed" with zero params (blank LCD) instead
        // of exercising the real plugin-edit paging.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "get_plugin_params",
                                         arguments: ["track": .string("Vocal"), "slot": .int(0)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        let params = json["params"] as! [[String: Any]]
        XCTAssertEqual(params.count, 10)                       // ChanEQ fixture has 10 → proves paging
        XCTAssertEqual(params[0]["name"] as? String, "LowFrq")
        XCTAssertEqual(params[8]["name"] as? String, "HPFrq")  // page 2
        _ = fake
    }

    func testSetPluginParamByName() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_plugin_param", arguments: [
            "track": .string("Vocal"), "slot": .int(0), "param": .string("HiGain"), "value": .double(0.75),
        ])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["display"] as? String, "0.75")
        let state = await fake.state
        XCTAssertEqual(state[10].plugins[0].params[6].value, 0.75, accuracy: 0.03)
    }

    func testSetPluginParamUnknownName() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`) — same
        // "FakeLogic [weak self]" gotcha as above.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_plugin_param", arguments: [
            "track": .string("Vocal"), "slot": .int(0), "param": .string("Wobble"), "value": .double(0.5),
        ])
        XCTAssertEqual(result.isError, true)
        _ = fake
    }

    func testGetPluginParamsEmptySlotIsError() async throws {
        // NOTE: retains `fake` (brief's literal test discarded it as `_`) — same
        // "FakeLogic [weak self]" gotcha as the other plugin tests.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        // Vocal's fixture only populates slot 0 (ChanEQ); slot 1 is empty, and
        // pressing vpotPress(1) in plugin-select mode is a no-op in FakeLogic —
        // this must be reported as a structured error, not fabricated success.
        let result = await registry.call(name: "get_plugin_params",
                                         arguments: ["track": .string("Vocal"), "slot": .int(1)])
        XCTAssertEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["layer"] as? String, "mcu")
        let message = json["error"] as? String ?? ""
        XCTAssertTrue(message.lowercased().contains("no plugin") && message.contains("slot 1"),
                      "expected a 'no plugin in slot 1' message, got: \(message)")
        _ = fake
    }

    func testUndoLastRestoresVolume() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-2.0)])
        let result = await registry.call(name: "undo_last", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        let state = await fake.state
        XCTAssertEqual(state[10].volumeRaw, FaderCurve.raw(fromDB: -6.0))
    }

    func testUndoLastTwoSpansTools() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Kick"), "db": .double(-9.0)])
        _ = await registry.call(name: "undo_last", arguments: ["n": .int(2)])
        let state = await fake.state
        XCTAssertFalse(state[6].mute)                    // mute undone
        XCTAssertEqual(state[0].volumeRaw, 12443)        // volume back to initial 0 dB
    }

    func testUndoLastNegativeNIsSafe() async throws {
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        let result = await registry.call(name: "undo_last", arguments: ["n": .int(-1)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual((json["undone"] as! [Any]).count, 0)
        let state = await fake.state
        XCTAssertTrue(state[6].mute)   // still muted — nothing was undone
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
        // JSON `db: -12` decodes to `.int(-12)`; it must be accepted and land at the
        // same fader position as `db: -12.0`.
        let (_, registryInt, fakeInt) = await makeDaemonWithFakeLogic()
        let intResult = await registryInt.call(name: "set_volume",
                                               arguments: ["track": .string("Vocal"), "db": .int(-12)])
        XCTAssertNotEqual(intResult.isError, true, "integer dB must be accepted, not rejected")
        let intRaw = try resultJSON(intResult)["volumeRaw"] as? Int

        let (_, registryDouble, fakeDouble) = await makeDaemonWithFakeLogic()
        let doubleResult = await registryDouble.call(name: "set_volume",
                                                     arguments: ["track": .string("Vocal"), "db": .double(-12.0)])
        let doubleRaw = try resultJSON(doubleResult)["volumeRaw"] as? Int

        XCTAssertEqual(intRaw, doubleRaw, ".int(-12) and .double(-12.0) must echo the same raw")
        XCTAssertEqual(intRaw, FaderCurve.raw(fromDB: -12.0))
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

    func testSetPluginParamAcceptsIntegerBoundaryValues() async throws {
        // value: 1 (fully open) and value: 0 (bypassed) are the most natural things a
        // caller writes; both decode to `.int` and must be accepted at the 0…1 bounds.
        let (_, registryOne, fakeOne) = await makeDaemonWithFakeLogic()
        let openResult = await registryOne.call(name: "set_plugin_param", arguments: [
            "track": .string("Vocal"), "slot": .int(0), "param": .string("HiGain"), "value": .int(1),
        ])
        XCTAssertNotEqual(openResult.isError, true, "value: 1 must be accepted")
        let openState = await fakeOne.state
        XCTAssertEqual(openState[10].plugins[0].params[6].value, 1.0, accuracy: 0.03)

        let (_, registryZero, fakeZero) = await makeDaemonWithFakeLogic()
        let zeroResult = await registryZero.call(name: "set_plugin_param", arguments: [
            "track": .string("Vocal"), "slot": .int(0), "param": .string("HiGain"), "value": .int(0),
        ])
        XCTAssertNotEqual(zeroResult.isError, true, "value: 0 must be accepted")
        let zeroState = await fakeZero.state
        XCTAssertEqual(zeroState[10].plugins[0].params[6].value, 0.0, accuracy: 0.03)
        _ = fakeOne
        _ = fakeZero
    }

    func testSetPanAcceptsIntegralDoubleButRejectsFractional() async throws {
        // `position: -30.0` is an integral double and must be accepted; `position: 2.5`
        // is fractional and must be REJECTED, never truncated to 2.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let ok = await registry.call(name: "set_pan",
                                     arguments: ["track": .string("Keys"), "position": .double(-30.0)])
        XCTAssertNotEqual(ok.isError, true, "integral double position must be accepted")
        var state = await fake.state
        XCTAssertEqual(state[9].pan, 34)   // 64 + (-30)

        let rejected = await registry.call(name: "set_pan",
                                           arguments: ["track": .string("Keys"), "position": .double(2.5)])
        XCTAssertEqual(rejected.isError, true, "fractional position must be rejected, not truncated")
        state = await fake.state
        XCTAssertEqual(state[9].pan, 34, "pan must be unchanged after the rejected 2.5")
        _ = fake
    }

    func testSetSendAcceptsIntegralDoubleLevel() async throws {
        // `level: 100.0` decodes to `.double(100.0)`; an integral double must be accepted.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        let result = await registry.call(name: "set_send", arguments: [
            "track": .string("Vocal"), "bus": .string("Bus 2"), "level": .double(100.0),
        ])
        XCTAssertNotEqual(result.isError, true, "integral double level must be accepted")
        let json = try resultJSON(result)
        XCTAssertEqual(json["level"] as? Int, 100)
        let state = await fake.state
        XCTAssertEqual(state[10].sends[1].level, 100)
        _ = fake
    }

    func testUndoLastAcceptsDoubleN() async throws {
        // `n: 2.0` decodes to `.double(2.0)` and must behave like `.int(2)`.
        let (_, registry, fake) = await makeDaemonWithFakeLogic()
        _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
        _ = await registry.call(name: "set_volume", arguments: ["track": .string("Kick"), "db": .double(-9.0)])
        _ = await registry.call(name: "undo_last", arguments: ["n": .double(2.0)])
        let state = await fake.state
        XCTAssertFalse(state[6].mute, "both mutations must be undone when n is a double")
        XCTAssertEqual(state[0].volumeRaw, 12443)
        _ = fake
    }
}
