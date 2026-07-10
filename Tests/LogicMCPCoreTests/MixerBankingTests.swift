import XCTest
import MCP
@testable import LogicMCPCore

/// Bank/channel-window semantics of real Logic Pro, verified empirically on a
/// 20-strip project, and the MixerNavigator enumeration/banking that rides on them.
///
/// Facts (N strips, maxOffset = max(0, N-8), offset = leftmost visible strip):
///   bankRight:    offset = min(((offset/8)+1)*8, maxOffset)   // snap up to grid, clamp right
///   bankLeft:     offset = max(((offset+7)/8 - 1)*8, 0)       // snap back to grid
///   channelRight: offset = min(offset+1, maxOffset)
///   channelLeft:  offset = max(offset-1, 0)
/// The LAST bank window is clamped to maxOffset and OVERLAPS the previous one.
final class MixerBankingTests: XCTestCase {
    // MARK: - Fixtures

    /// N tracks with distinct, resolvable names ("T00", "T01", …).
    static func tracks(_ n: Int) -> [FakeLogic.FakeTrack] {
        (0..<n).map { FakeLogic.FakeTrack(name: String(format: "T%02d", $0)) }
    }

    static func name(_ i: Int) -> String { String(format: "T%02d", i) }

    /// 20 tracks whose overlap region (indices 12..15) renders to the SAME 7-char
    /// LCD cells as indices 16..19. Proves enumeration relies on window geometry, not
    /// on content matching, to de-duplicate the overlap.
    static func ambiguousOverlap20() -> [FakeLogic.FakeTrack] {
        let overlap = ["ovl4", "ovl5", "ovl6", "ovl7"]
        let names = (0..<12).map { String(format: "T%02d", $0) } + overlap + overlap
        return names.map { FakeLogic.FakeTrack(name: $0) }
    }

    // MARK: - Harnesses

    /// Bare wire + fake, no session. Drive raw commands, read `fake.bankOffset`.
    private func makePair(_ tracks: [FakeLogic.FakeTrack], ignoreChannelScroll: Bool = false)
        async -> (daemon: InMemoryWire, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks, ignoreChannelScroll: ignoreChannelScroll)
        await fake.start()
        return (daemonEnd, fake)
    }

    /// Full session + navigator over a fake, handshake settled.
    private func makeNav(_ tracks: [FakeLogic.FakeTrack], ignoreChannelScroll: Bool = false)
        async -> (nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks, ignoreChannelScroll: ignoreChannelScroll)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel())
        return (nav, fake)
    }

    /// Daemon + registry over a fake, handshake settled. Retains the daemon.
    private func makeDaemon(_ tracks: [FakeLogic.FakeTrack])
        async -> (daemon: Daemon, registry: ToolRegistry, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: tracks)
        let daemon = await Daemon(wire: daemonEnd, axProvider: FakeAXProvider(root: FakeAXNode(role: "AXApplication")))
        await fake.start()
        let registry = ToolRegistry()
        await daemon.registerAllTools(in: registry)
        _ = await daemon.session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        return (daemon, registry, fake)
    }

    // MARK: - Deterministic driving

    /// Collect events from the daemon end until `predicate` matches or timeout.
    /// InMemoryWire replays full history to each subscriber, so this is race-free
    /// regardless of when it attaches relative to the emit.
    private static func awaitEvent(_ wire: InMemoryWire, timeout: Duration = .seconds(2),
                                   where predicate: @escaping @Sendable (MCUEvent) -> Bool) async -> MCUEvent? {
        let stream = wire.packets()
        return await withTaskGroup(of: MCUEvent?.self) { group in
            group.addTask {
                for await packet in stream {
                    if let event = MCUCodec.decodeEvent(packet), predicate(event) { return event }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }

    private var fenceValue = 9000

    /// Fence: a fader move with a value used exactly once, whose echo we await. Because
    /// FakeLogic's packet loop is serial, the echo proves every prior command was
    /// processed; because the value is unique, history replay can't match it early.
    private func fence(_ daemon: InMemoryWire) async {
        fenceValue += 1
        let v = fenceValue
        async let echo = Self.awaitEvent(daemon) {
            if case .faderEcho(0, v) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.faderMove(channel: 0, value: v)))
        _ = await echo
    }

    /// Press each button (press+release), fence, then read the fake's bank offset.
    private func offsetAfter(_ daemon: InMemoryWire, _ fake: FakeLogic,
                             driving buttons: [MCUButton]) async -> Int {
        for b in buttons {
            await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(b)))
            await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(b)))
        }
        await fence(daemon)
        return await fake.bankOffset
    }

    // MARK: - FakeLogic semantics (item 1)

    func testBankRightClampsAndBankLeftSnapsToGrid() async {
        let (daemon, fake) = await makePair(Self.tracks(20))   // maxOffset = 12
        var o = await offsetAfter(daemon, fake, driving: [.bankRight])
        XCTAssertEqual(o, 8)                                    // 0 -> 8
        o = await offsetAfter(daemon, fake, driving: [.bankRight])
        XCTAssertEqual(o, 12)                                   // 8 -> 12 (clamped)
        o = await offsetAfter(daemon, fake, driving: [.bankRight])
        XCTAssertEqual(o, 12)                                   // clamped no-op
        o = await offsetAfter(daemon, fake, driving: [.bankLeft])
        XCTAssertEqual(o, 8)                                    // 12 -> 8 (grid, NOT 4)
        o = await offsetAfter(daemon, fake, driving: [.bankLeft])
        XCTAssertEqual(o, 0)                                    // 8 -> 0
        o = await offsetAfter(daemon, fake, driving: [.bankLeft])
        XCTAssertEqual(o, 0)                                    // no-op at 0
        _ = fake
    }

    func testBankRightFromChannelScrolledOffsetSnapsToGrid() async {
        let (daemon, fake) = await makePair(Self.tracks(20))
        var o = await offsetAfter(daemon, fake, driving: [.channelRight, .channelRight])
        XCTAssertEqual(o, 2)
        o = await offsetAfter(daemon, fake, driving: [.bankRight])
        XCTAssertEqual(o, 8)                                    // 2 -> 8, NOT 10
        _ = fake
    }

    func testChannelScrollStepsByOneAndClamps() async {
        let (daemon, fake) = await makePair(Self.tracks(20))   // maxOffset = 12
        var o = await offsetAfter(daemon, fake, driving: [.channelRight])
        XCTAssertEqual(o, 1)
        o = await offsetAfter(daemon, fake, driving: [.channelRight])
        XCTAssertEqual(o, 2)
        o = await offsetAfter(daemon, fake, driving: [.channelLeft])
        XCTAssertEqual(o, 1)
        o = await offsetAfter(daemon, fake, driving: [.channelLeft])
        XCTAssertEqual(o, 0)
        o = await offsetAfter(daemon, fake, driving: [.channelLeft])
        XCTAssertEqual(o, 0)                                    // clamp at 0
        // Walk up to maxOffset: 0 ->(x12) 12, then no-op.
        let toMax = Array(repeating: MCUButton.channelRight, count: 12)
        o = await offsetAfter(daemon, fake, driving: toMax)
        XCTAssertEqual(o, 12)
        o = await offsetAfter(daemon, fake, driving: [.channelRight])
        XCTAssertEqual(o, 12)                                   // clamp at maxOffset
        _ = fake
    }

    func testChannelRightPagesPluginParamsInPluginEditMode() async {
        // In plugin-edit mode CHANNEL± must page params, NOT scroll the mixer.
        let (daemon, fake) = await makePair(FakeLogic.standardSession())
        // Enter plugin-edit on the default-selected track's slot 0 (ChanEQ, 10 params).
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.assignPlugin)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.assignPlugin)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.vpotPress(channel: 0))))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.vpotPress(channel: 0))))
        // channelRight should reveal page 2 (param index 8 = "HPFrq"), leaving bankOffset at 0.
        async let paged = Self.awaitEvent(daemon) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("HPFrq") } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.channelRight)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.channelRight)))
        let pagedResult = await paged
        XCTAssertNotNil(pagedResult, "channelRight should page plugin params in plugin-edit mode")
        let offset = await fake.bankOffset
        XCTAssertEqual(offset, 0, "plugin-edit CHANNEL± must not scroll the mixer")
        _ = fake
    }

    // MARK: - enumerateTracks exact counts (item 2)

    func testEnumerateExactCountsAndNamesAcrossSizes() async throws {
        for n in [5, 8, 9, 15, 16, 17, 20] {
            let (nav, fake) = await makeNav(Self.tracks(n))
            let names = try await nav.enumerateTracks()
            XCTAssertEqual(names.count, n, "N=\(n): wrong count")
            XCTAssertEqual(names, (0..<n).map(Self.name), "N=\(n): wrong names / duplicates")
            _ = fake
        }
    }

    // MARK: - Content-ambiguous overlap (item 3)

    func testEnumerateHandlesContentAmbiguousOverlap() async throws {
        let (nav, fake) = await makeNav(Self.ambiguousOverlap20())
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 20, "overlap must not be dropped or duplicated by content")
        let expected = (0..<12).map { String(format: "T%02d", $0) }
            + ["ovl4", "ovl5", "ovl6", "ovl7", "ovl4", "ovl5", "ovl6", "ovl7"]
        XCTAssertEqual(names, expected)
        _ = fake
    }

    func testStandardSessionStillEnumeratesWithGuitarCollision() async throws {
        // Guitar L / Guitar R (indices 7/8) both render "Guitar " across the bank boundary.
        let (nav, fake) = await makeNav(FakeLogic.standardSession())
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 16)
        XCTAssertEqual(names[7], "Guitar")
        XCTAssertEqual(names[8], "Guitar")
        XCTAssertEqual(names.last, "Mix Bus")
        _ = fake
    }

    // MARK: - bank(toShow:) in the clamped terminal window (item 4)

    func testBankToShowTerminalWindowAndKeepsOffsetInSync() async throws {
        let (nav, fake) = await makeNav(Self.tracks(20))   // maxOffset = 12
        _ = try await nav.enumerateTracks()

        // Index 18 lives only in the clamped terminal window (offset 12, channel 6).
        let ch = try await nav.bank(toShow: 18)
        var navOffset = await nav.bankOffset
        var fakeOffset = await fake.bankOffset
        XCTAssertEqual(ch, 6)
        XCTAssertEqual(navOffset, 12)
        XCTAssertEqual(navOffset, fakeOffset)
        XCTAssertEqual(navOffset + ch, 18)

        // Bank left to a stride window, then right again — offsets stay in sync.
        let ch2 = try await nav.bank(toShow: 3)
        navOffset = await nav.bankOffset
        fakeOffset = await fake.bankOffset
        XCTAssertEqual(navOffset, 0)
        XCTAssertEqual(navOffset, fakeOffset)
        XCTAssertEqual(navOffset + ch2, 3)

        let ch3 = try await nav.bank(toShow: 16)
        navOffset = await nav.bankOffset
        fakeOffset = await fake.bankOffset
        XCTAssertEqual(navOffset, 12)
        XCTAssertEqual(navOffset, fakeOffset)
        XCTAssertEqual(navOffset + ch3, 16)

        // Overlap index 12 is reachable via the stride window (offset 8, channel 4).
        let ch4 = try await nav.bank(toShow: 12)
        navOffset = await nav.bankOffset
        fakeOffset = await fake.bankOffset
        XCTAssertEqual(navOffset, 8)
        XCTAssertEqual(navOffset, fakeOffset)
        XCTAssertEqual(navOffset + ch4, 12)
        XCTAssertTrue((0..<8).contains(ch4))
        _ = fake
    }

    // MARK: - fader targeting regression (item 5)

    /// Originally exercised via set_volume, which re-homed onto AX in a later task — AX
    /// addresses strips by name and never banks the MCU surface at all, so the "wrong physical
    /// channel" failure mode this test guards against can no longer occur through set_volume.
    /// set_pan still runs the MCU `resolveAndBank` path, so it stands in as the regression
    /// vehicle. The core offset/channel math is directly covered above by
    /// testBankToShowTerminalWindowAndKeepsOffsetInSync; this is the end-to-end confirmation
    /// that a real tool call lands on the right channel.
    func testSetPanTargetsCorrectTrackInTerminalWindow() async throws {
        let (daemon, registry, fake) = await makeDaemon(Self.tracks(20))
        _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
        let result = await registry.call(name: "set_pan",
                                         arguments: ["track": .string("T18"), "position": .int(-30)])
        XCTAssertNotEqual(result.isError, true)
        let state = await fake.state
        XCTAssertEqual(state[18].pan, 34, "pan hit the wrong track")   // 64 + (-30)
        XCTAssertEqual(state[17].pan, 64, "neighbor moved")
        XCTAssertEqual(state[19].pan, 64, "neighbor moved")
        _ = daemon
        _ = fake
    }

    // MARK: - fallback when CHANNEL± is unavailable (item 6)

    func testEnumerateFallsBackWhenChannelScrollUnavailable() async throws {
        let (nav, fake) = await makeNav(Self.tracks(20), ignoreChannelScroll: true)
        let names = try await nav.enumerateTracks()
        // Degrades to the pre-fix behavior: concatenate every window's non-blank cells
        // (3 windows × 8 = 24), overlap duplicated. No worse than the status quo, no crash.
        XCTAssertEqual(names.count, 24)
        _ = fake
    }
}
