import XCTest
import MCP
@testable import LogicMCPCore

/// End-to-end tests that a parameter/banner view left on the LCD can never be read as track
/// names by `enumerateTracks`. (`set_volume` and `set_pan` were MCU/banner-sourced when this
/// file was written; both are AX-based now — see `AXMixToolTests` for their convergence
/// coverage. `set_automation_mode` is the only mix tool still MCU-sourced.) These tests drive
/// the MCU surface directly (`nav.enumerateTracks()`/`session.moveFader`), never through a
/// tool, so they need no AX fixture at all.
final class SurfaceReadbackTests: XCTestCase {
    static func tracks(_ n: Int) -> [FakeLogic.FakeTrack] {
        (0..<n).map { FakeLogic.FakeTrack(name: String(format: "T%02d", $0)) }
    }

    /// Session + navigator over a fake, with a SHORT banner timeout so recovery tests are
    /// fast. Keeps the session so the test can drive the surface directly. Retains the fake.
    private func makeNav(_ tracks: [FakeLogic.FakeTrack],
                         bannerTimeout: Duration = .milliseconds(150),
                         bannerLifetime: Duration = .milliseconds(200),
                         singleParameterPage: Bool = false, panStuck: Bool = false)
        async -> (session: MCUSession, nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks, bannerLifetime: bannerLifetime,
                             singleParameterPage: singleParameterPage, panStuck: panStuck)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel(), bannerTimeout: bannerTimeout)
        return (session, nav, fake)
    }

    // `set_pan` was re-homed onto AX (Task 7): it no longer sweeps a V-Pot, reads the LCD, or
    // can be made to "snap" relative to the request, so the three tests that used to live here
    // (observed-vs-requested snap, back-to-back calls surviving the `.assignPan` toggle bug,
    // and surviving a coalesced/missing ring echo) no longer have an MCU pan path to guard.
    // Direct-write + read-back convergence coverage for AX pan lives in
    // `AXMixToolTests.testSetPanWritesAndReadsBack`.

    // MARK: - the display-state hazard: enumeration must never read a banner/param view

    func testEnumerateWaitsOutVolumeBannerAndReadsRealNames() async throws {
        // Drive a fader move DIRECTLY at the MCU layer (the same `moveFader` call `set_volume`
        // makes internally) — this is what leaves a transient "Volume" banner on channel 0's
        // name/pan cells in real Logic. Then call `nav.enumerateTracks()` itself (never the
        // `refresh_state` tool, which is AX-sourced and never touches the MCU LCD) and prove
        // `ensureNameRow`/`pollForNames` wait the banner out rather than reading "Volume" as
        // track 0's name. The banner (300ms) outlives enumeration's initial read but reverts
        // well inside `bannerTimeout` (800ms), so the only way this test can pass is if the
        // wait-out loop actually waits.
        let (session, nav, fake) = await makeNav(Self.tracks(10),
                                                  bannerTimeout: .milliseconds(800),
                                                  bannerLifetime: .milliseconds(300))
        let stream = await session.events()
        _ = try await session.moveFader(channel: 0, toRaw: 6000, timeout: .seconds(1))
        let banner = await MCUSession.first(of: stream, timeout: .seconds(1)) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("Volume") } else { return false }
        }
        XCTAssertNotNil(banner, "fixture never painted the volume banner on channel 0's LCD cell")

        let names = try await nav.enumerateTracks()
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
