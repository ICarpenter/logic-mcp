import XCTest
@testable import LogicMCPCore

final class AXStripTests: XCTestCase {
    func testParsesPositiveAndNegativeDB() {
        XCTAssertEqual(AXStrip.parseDB("volume fader level, 0.0 dB")?.db, 0.0)
        XCTAssertEqual(AXStrip.parseDB("volume fader level, -6.0 dB")?.db, -6.0)
        XCTAssertEqual(AXStrip.parseDB("volume fader level, +3.5 dB")?.db, 3.5)
    }
    func testParsesSilence() {
        let r = AXStrip.parseDB("volume fader level, -∞ dB")
        XCTAssertNotNil(r); XCTAssertNil(r?.db); XCTAssertEqual(r?.silent, true)
    }
    func testRejectsUnrelated() {
        XCTAssertNil(AXStrip.parseDB("peak level meter"))
    }
}
