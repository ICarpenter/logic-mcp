import XCTest
@testable import LogicMCPCore

final class FaderCurveTests: XCTestCase {
    // MARK: - Unity

    func testUnityRoundTripsExactly() {
        // Measured: unity (0.0 dB) is at raw 12443, not the guessed 12288.
        XCTAssertEqual(FaderCurve.dB(fromRaw: 12443)!, 0.0, accuracy: 0.001)
        XCTAssertEqual(FaderCurve.raw(fromDB: 0.0), 12443)
    }

    // MARK: - Saturation

    func testSaturationClampsAtPlus6() {
        // The fader saturates at raw 14845 = +6.0 dB; requests above echo back 14845.
        XCTAssertEqual(FaderCurve.dB(fromRaw: 14845)!, 6.0, accuracy: 0.001)
        XCTAssertEqual(FaderCurve.raw(fromDB: 6.0), 14845)
        XCTAssertEqual(FaderCurve.raw(fromDB: 12.0), 14845)   // any db >= 6.0 clamps to 14845
    }

    func testPositionsAboveSaturationReportPlus6() {
        // The old table stretched to 16383 and read this position as ~3.7 dB.
        // Real Logic saturates: anything at/above 14845 is +6.0.
        XCTAssertEqual(FaderCurve.dB(fromRaw: 16383)!, 6.0, accuracy: 0.001)
        XCTAssertEqual(FaderCurve.dB(fromRaw: 15360)!, 6.0, accuracy: 0.001)
    }

    // MARK: - Silence ceiling

    func testSilenceCeilingIsRaw7() {
        XCTAssertNil(FaderCurve.dB(fromRaw: 0))    // -∞
        XCTAssertNil(FaderCurve.dB(fromRaw: 7))    // still -∞ (Logic shows -oo up to raw 7)
        XCTAssertNotNil(FaderCurve.dB(fromRaw: 15)) // raw 15 → Logic shows -138 dB, not silent
    }

    func testIsSilentAgreesWithNilBoundary() {
        // isSilent(raw:) exists so callers ask "is this position silent?" instead of
        // hardcoding a magic comparison. It must agree with dB(fromRaw:) returning nil.
        for raw in [0, 1, 5, 7, 8, 15, 100, 12443, 14845] {
            XCTAssertEqual(FaderCurve.isSilent(raw: raw), FaderCurve.dB(fromRaw: raw) == nil,
                           "isSilent disagreed with the nil boundary at raw \(raw)")
        }
        XCTAssertTrue(FaderCurve.isSilent(raw: 7))
        XCTAssertFalse(FaderCurve.isSilent(raw: 8))
    }

    // MARK: - The single most-wrong old value

    func testMidScaleAnchorMatchesMeasurement() {
        // Old (guessed) table read raw 8178 as -12.1 dB; measured value is -9.0.
        XCTAssertEqual(FaderCurve.dB(fromRaw: 8178)!, -9.0, accuracy: 0.001)
    }

    // MARK: - Bottom clamp

    func testWellBelowBottomAnchorClampsToSilence() {
        XCTAssertEqual(FaderCurve.raw(fromDB: -200), 0)   // below the measured range → -∞
    }

    // MARK: - Monotonicity

    func testMonotonicNonDecreasingAcrossAudibleRange() {
        var previous = -Double.infinity
        for raw in stride(from: 8, through: 14845, by: 1) {
            let db = FaderCurve.dB(fromRaw: raw)!
            XCTAssertGreaterThanOrEqual(db, previous, "curve dipped at raw \(raw)")
            previous = db
        }
    }

    // MARK: - Exact anchor round-trips

    func testEveryAnchorRoundTripsToItsRaw() {
        for anchor in FaderCurve.anchors {
            XCTAssertEqual(FaderCurve.raw(fromDB: anchor.db), anchor.raw,
                           "raw(fromDB: \(anchor.db)) should return \(anchor.raw)")
        }
    }

    func testEveryAnchorRawReportsItsDB() {
        for anchor in FaderCurve.anchors {
            XCTAssertEqual(FaderCurve.dB(fromRaw: anchor.raw)!, anchor.db, accuracy: 0.001,
                           "dB(fromRaw: \(anchor.raw)) should return \(anchor.db)")
        }
    }

    // MARK: - Round-trip tolerance across the working range

    func testRoundTripToleranceAcrossRange() {
        for db in stride(from: -30.0, through: 6.0, by: 0.5) {
            let back = FaderCurve.dB(fromRaw: FaderCurve.raw(fromDB: db))!
            XCTAssertEqual(back, db, accuracy: 0.15, "round trip broke at \(db) dB")
        }
    }
}
