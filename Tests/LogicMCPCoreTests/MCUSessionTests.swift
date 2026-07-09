import XCTest
@testable import LogicMCPCore

final class MCUSessionTests: XCTestCase {
    private func makeSession() async -> (session: MCUSession, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        return (session, fake)
    }

    func testHandshakeCompletesAndLCDArrives() async {
        let (session, fake) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let surface = await session.surface
        XCTAssertTrue(surface.connected)
        XCTAssertEqual(surface.lcdCell(line: 0, channel: 0), "Kick   ")
        XCTAssertEqual(surface.lcdCell(line: 0, channel: 6), "Bass   ")
        _ = fake  // keep FakeLogic's actor alive: its own listener task holds only a weak
                  // self-reference, so the caller must retain it for the handshake to complete.
    }

    func testMoveFaderReturnsEcho() async throws {
        let (session, fake) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let echoed = try await session.moveFader(channel: 2, toRaw: 4096, timeout: .seconds(1))
        XCTAssertEqual(echoed, 4096)
        let state = await fake.state
        XCTAssertEqual(state[2].volumeRaw, 4096)
        let surface = await session.surface
        XCTAssertEqual(surface.faderRaw[2], 4096)
    }

    func testMoveFaderTimesOutAsToolFailure() async {
        // Dead wire: no FakeLogic on the other end.
        let (daemonEnd, _) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        do {
            _ = try await session.moveFader(channel: 0, toRaw: 100, timeout: .milliseconds(150))
            XCTFail("expected ToolFailure")
        } catch let failure as ToolFailure {
            XCTAssertEqual(failure.layer, "mcu")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testLEDStateTracked() async {
        let (session, fake) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        async let led = session.waitFor(timeout: .seconds(1)) {
            if case .led(.play, .on) = $0 { return true } else { return false }
        }
        await session.press(.play)
        let ledReceived = await led
        XCTAssertNotNil(ledReceived)
        let surface = await session.surface
        XCTAssertEqual(surface.leds[.play], .on)
        _ = fake  // keep FakeLogic's actor alive: its own listener task holds only a weak
                  // self-reference, so the caller must retain it for events to keep flowing.
    }
}
