import XCTest
@testable import LogicMCPCore

final class TranscriptTests: XCTestCase {
    func testLoadFixtureAndHexParse() throws {
        let url = Bundle.module.url(forResource: "handshake", withExtension: "jsonl",
                                    subdirectory: "Fixtures")!
        let entries = try Transcript.load(url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].dir, "in")
        XCTAssertEqual(Transcript.bytes(entries[0]), [0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7])
    }

    func testInMemoryWirePairIsCrossConnected() async {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let stream = logicEnd.packets()
        await daemonEnd.send([0x90, 0x5E, 0x7F])
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, [0x90, 0x5E, 0x7F])
    }

    func testScriptedWireReplaysInEntriesAndRecordsSent() async throws {
        let transcript = [
            TranscriptEntry(dir: "in", hex: "E0 00 40"),
            TranscriptEntry(dir: "in", hex: "90 5E 7F"),
        ]
        let wire = ScriptedWire(transcript: transcript)
        let stream = wire.packets()
        try await Task.sleep(for: .milliseconds(20))
        await wire.playNext(count: 2)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [0xE0, 0x00, 0x40])
        await wire.send([0x90, 0x5D, 0x7F])
        let sent = await wire.sent
        XCTAssertEqual(sent, [[0x90, 0x5D, 0x7F]])
    }
}
