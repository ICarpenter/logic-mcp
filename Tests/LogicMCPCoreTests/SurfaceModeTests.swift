import XCTest
@testable import LogicMCPCore

/// `MixerNavigator.normalizeSurface()` drives the two hidden MCU display toggles
/// (`.assignPan` = per-channel pan ⇄ single-parameter page, `.nameValue` = values ⇄ names)
/// to the one KNOWN state every mix tool relies on: per-channel pan with signed VALUES on the
/// bottom row. It must OBSERVE each axis and press a button only when the observed state
/// differs from the target — never blind, never assuming a press landed.
final class SurfaceModeTests: XCTestCase {
    static func tracks(_ n: Int) -> [FakeLogic.FakeTrack] {
        (0..<n).map { FakeLogic.FakeTrack(name: String(format: "T%02d", $0)) }
    }

    /// Session + navigator + fake started in a specific (axis1, axis2) combination. Retains
    /// the fake; the handshake LCD has already been consumed so the surface is painted.
    private func makeNav(singleParameterPage: Bool = false, showingValues: Bool = true,
                         panStuck: Bool = false)
        async -> (session: MCUSession, nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: Self.tracks(6),
                             singleParameterPage: singleParameterPage,
                             showingPanValues: showingValues, panStuck: panStuck)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel())
        return (session, nav, fake)
    }

    private func assertNormalized(_ session: MCUSession,
                                  _ message: String, file: StaticString = #filePath,
                                  line: UInt = #line) async {
        let bottom = await session.surface.lcdBottom
        XCTAssertTrue(SurfaceDisplay.isPerChannelPan(bottom),
                      "\(message): not per-channel pan (bottom=\(bottom.debugDescription))",
                      file: file, line: line)
        XCTAssertTrue(SurfaceDisplay.isShowingValues(bottom),
                      "\(message): not showing values (bottom=\(bottom.debugDescription))",
                      file: file, line: line)
    }

    // MARK: - Reaches (per-channel pan, values) from all four starting combinations

    func testNormalizeFromPerChannelValuesIsANoOp() async throws {
        let (session, nav, fake) = await makeNav(singleParameterPage: false, showingValues: true)
        let before = await fake.pressCount
        try await nav.normalizeSurface()
        let after = await fake.pressCount
        XCTAssertEqual(after - before, 0, "already normalized — must press nothing")
        await assertNormalized(session, "perChannel+values")
        _ = fake
    }

    func testNormalizeFromPerChannelNames() async throws {
        let (session, nav, fake) = await makeNav(singleParameterPage: false, showingValues: false)
        let before = await fake.pressCount
        try await nav.normalizeSurface()
        let after = await fake.pressCount
        XCTAssertEqual(after - before, 1, "one NAME/VALUE press flips names → values")
        await assertNormalized(session, "perChannel+names")
        _ = fake
    }

    func testNormalizeFromSingleParameterValues() async throws {
        let (session, nav, fake) = await makeNav(singleParameterPage: true, showingValues: true)
        let before = await fake.pressCount
        try await nav.normalizeSurface()
        let after = await fake.pressCount
        XCTAssertEqual(after - before, 1, "one .assignPan press returns to per-channel pan")
        await assertNormalized(session, "singleParam+values")
        _ = fake
    }

    func testNormalizeFromSingleParameterNames() async throws {
        let (session, nav, fake) = await makeNav(singleParameterPage: true, showingValues: false)
        let before = await fake.pressCount
        try await nav.normalizeSurface()
        let after = await fake.pressCount
        XCTAssertEqual(after - before, 2, "axis 1 (.assignPan) then axis 2 (.nameValue)")
        await assertNormalized(session, "singleParam+names")
        _ = fake
    }

    // MARK: - Throws when a known state is unreachable

    func testNormalizeThrowsWhenSingleParameterPageIsStuck() async throws {
        let (_, nav, fake) = await makeNav(singleParameterPage: true, showingValues: false,
                                           panStuck: true)
        do {
            try await nav.normalizeSurface()
            XCTFail("expected a ToolFailure when the surface cannot reach a known state")
        } catch let failure as ToolFailure {
            XCTAssertEqual(failure.layer, "mcu")
        }
        _ = fake
    }
}
