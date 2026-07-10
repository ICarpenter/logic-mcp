import XCTest
import MCP
@testable import LogicMCPCore

/// End-to-end tests that `set_volume`/`set_pan` return Logic's OWN printed numbers (not the
/// requested value round-tripped through a curve), and that a parameter/banner view left on
/// the LCD can never be read as track names by `enumerateTracks`.
final class SurfaceReadbackTests: XCTestCase {
    static func tracks(_ n: Int) -> [FakeLogic.FakeTrack] {
        (0..<n).map { FakeLogic.FakeTrack(name: String(format: "T%02d", $0)) }
    }

    /// A minimal AX mixer mirroring `tracks`' names — these tests exercise MCU-sourced tools
    /// (`set_volume`/`set_pan`, which go through `MixerNavigator`, never AX), but `refresh_state`
    /// is now AX-only, so a call to it needs a non-empty mixer to read.
    private static func axProvider(for tracks: [FakeLogic.FakeTrack]) -> FakeAXProvider {
        let strips = tracks.map { FakeAXNode(role: "AXLayoutItem", description: $0.name) }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: strips)
        let window = FakeAXNode(role: "AXWindow", children: [area])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
    }

    /// Daemon + registry over a fake whose LCD-display behaviour is tunable. Retains the fake.
    private func makeDaemon(_ tracks: [FakeLogic.FakeTrack],
                            bannerLifetime: Duration = .milliseconds(200),
                            ringEchoes: Bool = true,
                            panSnap: (@Sendable (Int) -> Int)? = nil)
        async -> (daemon: Daemon, registry: ToolRegistry, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks,
                             bannerLifetime: bannerLifetime, ringEchoes: ringEchoes, panSnap: panSnap)
        let daemon = await Daemon(wire: daemonEnd, axProvider: Self.axProvider(for: tracks))
        await fake.start()
        let registry = ToolRegistry()
        await daemon.registerAllTools(in: registry)
        _ = await daemon.session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        return (daemon, registry, fake)
    }

    /// Session + navigator over a fake, with a SHORT banner timeout so recovery tests are
    /// fast. Keeps the session so the test can drive the surface directly. Retains the fake.
    private func makeNav(_ tracks: [FakeLogic.FakeTrack],
                         bannerTimeout: Duration = .milliseconds(150),
                         singleParameterPage: Bool = false, panStuck: Bool = false)
        async -> (session: MCUSession, nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks,
                             singleParameterPage: singleParameterPage, panStuck: panStuck)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel(), bannerTimeout: bannerTimeout)
        return (session, nav, fake)
    }

    private func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
        guard case .text(let json, _, _)? = result.content.first else {
            throw ToolFailure(error: "no text", layer: "daemon")
        }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: - set_volume returns Logic's LCD dB

    func testSetVolumeReturnsLogicDBWithSourceLogic() async throws {
        // Banner lives well past set_volume's 150ms read, so Logic's printed dB is used.
        let (_, registry, fake) = await makeDaemon(Self.tracks(4), bannerLifetime: .milliseconds(900))
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("T00"), "db": .double(-6.0)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["source"] as? String, "logic",
                       "with a live banner, the dB must come from Logic's LCD")
        XCTAssertEqual(json["volumeDB"] as! Double, -6.0, accuracy: 0.2)
        _ = fake
    }

    func testSetVolumeFallsBackToCurveWhenBannerAbsent() async throws {
        // bannerLifetime .zero => the fake never paints a banner, so the tool must fall back
        // to the calibrated curve and say so.
        let (_, registry, fake) = await makeDaemon(Self.tracks(4), bannerLifetime: .zero)
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "set_volume",
                                         arguments: ["track": .string("T00"), "db": .double(-6.0)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["source"] as? String, "curve",
                       "with no banner, the dB must be interpolated from the curve")
        XCTAssertEqual(json["volumeDB"] as! Double, -6.0, accuracy: 0.2)
        _ = fake
    }

    // MARK: - set_pan returns the OBSERVED pan, not the requested one

    func testSetPanReturnsObservedPanNotRequested() async throws {
        // Logic snaps: it lands 5 higher (signed) than commanded. The tool must return what
        // the LCD shows (-25), never the requested -30.
        let (_, registry, fake) = await makeDaemon(Self.tracks(4), panSnap: { $0 + 5 })
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("T01"), "position": .int(-30)])
        XCTAssertNotEqual(result.isError, true)
        let json = try resultJSON(result)
        XCTAssertEqual(json["pan"] as? Int, -25, "must return Logic's observed pan, not the request")
        XCTAssertEqual(json["source"] as? String, "logic")

        // The shadow model must also hold the observed pan.
        let get = await registry.call(name: "get_track", arguments: ["name": .string("T01")])
        XCTAssertEqual(try resultJSON(get)["pan"] as? Int, -25)
        _ = fake
    }

    func testSetPanWorksOnTwoConsecutiveCalls() async throws {
        // The old bug pressed .assignPan unconditionally, TOGGLING per-channel pan on and off,
        // so the tool alternated between working and moving nothing on a non-zero channel.
        // normalizeSurface keeps the surface in per-channel pan, so back-to-back calls land.
        let (_, registry, fake) = await makeDaemon(Self.tracks(4))
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])

        let first = await registry.call(name: "set_pan",
                                        arguments: ["track": .string("T02"), "position": .int(-20)])
        XCTAssertNotEqual(first.isError, true)
        XCTAssertEqual(try resultJSON(first)["pan"] as? Int, -20)
        XCTAssertEqual(try resultJSON(first)["source"] as? String, "logic")

        let second = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("T02"), "position": .int(40)])
        XCTAssertNotEqual(second.isError, true, "the second consecutive call must also land")
        XCTAssertEqual(try resultJSON(second)["pan"] as? Int, 40)
        XCTAssertEqual(try resultJSON(second)["source"] as? String, "logic")

        let state = await fake.state
        XCTAssertEqual(state[2].pan, 104)   // 64 + 40, T02 is channel 2 (non-zero)
        _ = fake
    }

    func testSetPanSucceedsWhenLogicEmitsNoRingEcho() async throws {
        // Measured on real Logic: the two turn bursts arrive faster than the LED ring
        // refreshes, so Logic coalesces them. Sweeping -47 → -64 → -47 leaves the ring where
        // it started and Logic emits NO ring echo — which happens precisely when the pan is
        // ALREADY at the requested value. The old code waited on that echo and reported
        // "pan not confirmed" for a move that was already correct. Verification must come
        // from the pan Logic PRINTS, never from a ring echo.
        let (_, registry, fake) = await makeDaemon(Self.tracks(4), ringEchoes: false)
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])

        let result = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("T02"), "position": .int(-47)])
        XCTAssertNotEqual(result.isError, true, "no ring echo must NOT mean 'pan not confirmed'")
        XCTAssertEqual(try resultJSON(result)["pan"] as? Int, -47)
        XCTAssertEqual(try resultJSON(result)["source"] as? String, "logic")

        // Ask for the value it already holds — the real-world no-echo case.
        let again = await registry.call(name: "set_pan",
                                        arguments: ["track": .string("T02"), "position": .int(-47)])
        XCTAssertNotEqual(again.isError, true, "re-requesting the current pan must still succeed")
        XCTAssertEqual(try resultJSON(again)["pan"] as? Int, -47)

        let state = await fake.state
        XCTAssertEqual(state[2].pan, 17)   // 64 + (-47)
        _ = fake
    }

    // MARK: - the display-state hazard: enumeration must never read a banner/param view

    func testEnumerateWaitsOutVolumeBannerAndReadsRealNames() async throws {
        // set_volume on the channel-0 track leaves a "Volume" banner on the name row.
        // The very next refresh_state must NOT return "Volume" as track 0's name.
        let (_, registry, fake) = await makeDaemon(Self.tracks(10), bannerLifetime: .milliseconds(600))
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        _ = await registry.call(name: "set_volume",
                                arguments: ["track": .string("T00"), "db": .double(-6.0)])
        let result = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        XCTAssertNotEqual(result.isError, true)
        let tracks = try resultJSON(result)["tracks"] as! [[String: Any]]
        let names = tracks.map { $0["name"] as! String }
        XCTAssertEqual(names, (0..<10).map { String(format: "T%02d", $0) },
                       "the volume banner must not poison enumeration")
        _ = fake
    }

    func testEnumerateRecoversFromSingleParameterPage() async throws {
        // AXIS 1: the single-parameter page pins a parameter header ("… Pan/Surround") on the
        // top row. enumerateTracks must normalize (press .assignPan back to per-channel pan,
        // which repaints the track names) and return the real names.
        let (_, nav, fake) = await makeNav(Self.tracks(5), singleParameterPage: true)
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names, (0..<5).map { String(format: "T%02d", $0) })
        _ = fake
    }

    func testEnumerateThrowsWhenSingleParameterPageIsStuck() async throws {
        // If .assignPan can never leave the single-parameter page, enumeration must THROW an
        // mcu failure — never hand back "Track 1"/"Pan/Surround" as if they were track names.
        let (_, nav, fake) = await makeNav(Self.tracks(5), singleParameterPage: true, panStuck: true)
        do {
            let names = try await nav.enumerateTracks()
            XCTFail("expected a ToolFailure, got names: \(names)")
        } catch let failure as ToolFailure {
            XCTAssertEqual(failure.layer, "mcu")
        }
        _ = fake
    }
}
