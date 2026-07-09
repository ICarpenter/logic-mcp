import XCTest
@testable import LogicMCPCore

final class FakeLogicTests: XCTestCase {
    private func makePair() async -> (daemon: InMemoryWire, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        return (daemonEnd, fake)
    }

    /// Collect events from the daemon end until `predicate` matches or timeout.
    private static func awaitEvent(_ wire: InMemoryWire, timeout: Duration = .seconds(1),
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

    func testFaderMoveIsEchoedAndStored() async {
        let (daemon, fake) = await makePair()
        async let echo = Self.awaitEvent(daemon) {
            if case .faderEcho(0, 9000) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: true)))
        await daemon.send(MCUCodec.encode(MCUCommand.faderMove(channel: 0, value: 9000)))
        await daemon.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: false)))
        let received = await echo
        XCTAssertNotNil(received)
        let state = await fake.state
        XCTAssertEqual(state[0].volumeRaw, 9000)
    }

    func testMuteTogglesAndLEDEchoes() async {
        let (daemon, fake) = await makePair()
        async let led = Self.awaitEvent(daemon) {
            if case .led(.mute(channel: 2), .on) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.mute(channel: 2))))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.mute(channel: 2))))
        let received = await led
        XCTAssertNotNil(received)
        let state = await fake.state
        XCTAssertTrue(state[2].mute)
    }

    func testBankRightShiftsLCDNames() async {
        let (daemon, fake) = await makePair()
        // Track 8 (0-based) in the standard session is "Guitar R" → LCD cell "Guitar "
        async let lcd = Self.awaitEvent(daemon) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("Guitar ") } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.bankRight)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.bankRight)))
        let received = await lcd
        XCTAssertNotNil(received)
        let offset = await fake.bankOffset
        XCTAssertEqual(offset, 8)
    }

    func testPlayLightsPlayLED() async {
        let (daemon, fake) = await makePair()
        async let led = Self.awaitEvent(daemon) {
            if case .led(.play, .on) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.play)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.play)))
        let received = await led
        XCTAssertNotNil(received)
        let playing = await fake.isPlaying
        XCTAssertTrue(playing)
    }

    func testHandshakeEndsWithInitialLCD() async {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        async let lcd = Self.awaitEvent(daemonEnd, timeout: .seconds(2)) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("Kick") } else { return false }
        }
        async let query = Self.awaitEvent(daemonEnd) {
            if case .deviceQuery = $0 { return true } else { return false }
        }
        await fake.start()
        let queryReceived = await query
        XCTAssertNotNil(queryReceived)
        // Complete the handshake the way MCUSession will (Task 7):
        await daemonEnd.send(MCUCodec.encode(MCUCommand.hostConnectionQuery(
            serial: Array("LMCP001".utf8), challenge: [1, 2, 3, 4])))
        let lcdReceived = await lcd
        XCTAssertNotNil(lcdReceived)
    }
}
