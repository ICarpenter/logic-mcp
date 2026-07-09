import XCTest
@testable import LogicMCPCore

final class ProjectModelTests: XCTestCase {
    private func makeStack() async -> (session: MCUSession, model: ProjectModel, nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let model = ProjectModel()
        let nav = MixerNavigator(session: session, model: model)
        return (session, model, nav, fake)
    }

    func testEnumerateFindsAllSixteenTracks() async throws {
        let (_, _, nav, fake) = await makeStack()
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 16)
        XCTAssertEqual(names.first, "Kick")
        XCTAssertEqual(names[8], "Guitar")   // "Guitar R" truncated to LCD cell "Guitar "
        _ = fake
    }

    func testResolveExactAndPrefix() async throws {
        let (_, _, nav, fake) = await makeStack()
        _ = try await nav.enumerateTracks()
        let vocal = try await nav.resolve("Vocal")
        XCTAssertEqual(vocal.index, 10)      // exact match wins over "Vocal D"
        let bgv = try await nav.resolve("bg") // unique prefix, case-insensitive
        XCTAssertEqual(bgv.index, 12)
        _ = fake
    }

    func testResolveErrors() async throws {
        let (_, _, nav, fake) = await makeStack()
        _ = try await nav.enumerateTracks()
        do {
            _ = try await nav.resolve("Trombone")
            XCTFail("expected miss")
        } catch let failure as ToolFailure {
            XCTAssertTrue(failure.error.contains("no track"))
            XCTAssertTrue(failure.observed?.contains("Kick") ?? false)
        }
        do {
            _ = try await nav.resolve("Guitar")   // "Guitar" cell appears twice (L and R truncate identically)
            XCTFail("expected ambiguity")
        } catch let failure as ToolFailure {
            XCTAssertTrue(failure.error.contains("ambiguous"))
        }
        _ = fake
    }

    func testBankToShowReturnsLocalChannel() async throws {
        let (_, _, nav, fake) = await makeStack()
        _ = try await nav.enumerateTracks()
        let channel = try await nav.bank(toShow: 10)   // "Vocal"
        let offset = await fake.bankOffset
        XCTAssertEqual(offset + channel, 10)
        XCTAssertTrue((0..<8).contains(channel))
    }

    func testEnumerateTwelveTracksSkipsBlankCells() async throws {
        // Non-multiple-of-8: the last bank pads with 4 blank cells.
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let twelve = Array(FakeLogic.standardSession().prefix(12))
        let fake = FakeLogic(wire: logicEnd, tracks: twelve)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel())
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 12)
        XCTAssertEqual(names.last, "Vocal D")   // "Vocal Dbl" truncated to the 7-char cell
        _ = fake
    }
}
