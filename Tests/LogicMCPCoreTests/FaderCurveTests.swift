import XCTest
@testable import LogicMCPCore

final class FaderCurveTests: XCTestCase {
    func testEndpoints() {
        XCTAssertNil(FaderCurve.dB(fromRaw: 0))                       // -∞
        XCTAssertEqual(FaderCurve.dB(fromRaw: 16383)!, 6.0, accuracy: 0.01)
        XCTAssertEqual(FaderCurve.raw(fromDB: 6.0), 16383)
        XCTAssertEqual(FaderCurve.raw(fromDB: -200), 0)               // clamps to -∞
    }

    func testUnityAnchor() {
        XCTAssertEqual(FaderCurve.dB(fromRaw: 12288)!, 0.0, accuracy: 0.01)
        XCTAssertEqual(FaderCurve.raw(fromDB: 0.0), 12288)
    }

    func testMonotonic() {
        var previous = -Double.infinity
        for raw in stride(from: 1, through: 16383, by: 128) {
            let db = FaderCurve.dB(fromRaw: raw)!
            XCTAssertGreaterThan(db, previous, "curve must be strictly increasing at raw \(raw)")
            previous = db
        }
    }

    func testRoundTripWithinOneRawStep() {
        for raw in stride(from: 64, through: 16383, by: 517) {
            let db = FaderCurve.dB(fromRaw: raw)!
            XCTAssertEqual(FaderCurve.raw(fromDB: db), raw, accuracy: 35)
        }
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)")
}
