import XCTest
@testable import LogicMCPCore

/// Unit tests for the LCD display helpers that turn what Logic PRINTS on the surface
/// into ground-truth numbers. These reproduce the exact strings measured on real Logic
/// via `logic-mcp lcdprobe` (see the design brief), so they pin the parse contract.
final class SurfaceDisplayTests: XCTestCase {
    /// Build a 56-char LCD row (8 cells × 7 chars) from per-cell strings.
    private func row(_ cells: [String]) -> String {
        precondition(cells.count == 8)
        return cells.map { String($0.prefix(7)).padding(toLength: 7, withPad: " ", startingAt: 0) }
            .joined()
    }

    /// Place a 14-char (2-cell) value field starting at `cell`, filling the rest with spaces.
    private func fieldRow(_ text: String, atCell cell: Int) -> String {
        var cells = [String](repeating: "", count: 8)
        let padded = text.padding(toLength: 14, withPad: " ", startingAt: 0)
        cells[cell] = String(padded.prefix(7))
        cells[cell + 1] = String(padded.dropFirst(7))
        return row(cells)
    }

    private func surface(top: String = String(repeating: " ", count: 56),
                         bottom: String = String(repeating: " ", count: 56)) -> SurfaceState {
        var s = SurfaceState()
        s.lcdTop = top
        s.lcdBottom = bottom
        return s
    }

    // MARK: - valueText (the 2-cell volume-banner field)

    func testValueTextReadsChannelZeroFromCellsZeroAndOne() {
        let s = surface(bottom: fieldRow("-9.0 dB", atCell: 0))
        XCTAssertEqual(SurfaceDisplay.valueText(s, line: 1, channel: 0), "-9.0 dB")
    }

    func testValueTextReadsChannelSevenShiftedLeftToCellsSixAndSeven() {
        // Channel 7 has no cell 8 to spill into, so Logic shifts the field to cells 6+7.
        let s = surface(bottom: fieldRow("-9.0 dB", atCell: 6))
        XCTAssertEqual(SurfaceDisplay.valueText(s, line: 1, channel: 7), "-9.0 dB")
    }

    func testValueTextChannelSixAndSevenReadTheSamePair() {
        // min(channel, 6) means channels 6 and 7 both read cells 6+7.
        let s = surface(bottom: fieldRow("+0.0 dB", atCell: 6))
        XCTAssertEqual(SurfaceDisplay.valueText(s, line: 1, channel: 6), "+0.0 dB")
        XCTAssertEqual(SurfaceDisplay.valueText(s, line: 1, channel: 7), "+0.0 dB")
    }

    // MARK: - parseDB (outer nil = unparseable, inner nil = -oo silent)

    func testParseDBRegularValues() {
        for (text, expected) in [("-9.0 dB", -9.0), ("+0.0 dB", 0.0), ("-119 dB", -119.0)] {
            guard case .some(.some(let v)) = SurfaceDisplay.parseDB(text) else {
                return XCTFail("expected a parsed value for '\(text)'")
            }
            XCTAssertEqual(v, expected, accuracy: 0.001, "for '\(text)'")
        }
    }

    func testParseDBSilenceIsRecognizedButNil() {
        // "-oo dB" is a KNOWN reading (silent), distinct from unparseable garbage.
        guard case .some(.none) = SurfaceDisplay.parseDB("-oo dB") else {
            return XCTFail("expected recognized-silent (.some(.none)) for '-oo dB'")
        }
    }

    func testParseDBGarbageIsUnparseable() {
        for text in ["Kick", "", "   ", "Pan"] {
            guard case .none = SurfaceDisplay.parseDB(text) else {
                return XCTFail("expected unparseable (.none) for '\(text)'")
            }
        }
    }

    // MARK: - parsePan (-64 … +63, strip a leading '+')

    func testParsePanAcrossRange() {
        XCTAssertEqual(SurfaceDisplay.parsePan("-64"), -64)
        XCTAssertEqual(SurfaceDisplay.parsePan("0"), 0)
        XCTAssertEqual(SurfaceDisplay.parsePan("+63"), 63)
        XCTAssertEqual(SurfaceDisplay.parsePan("-30"), -30)
        XCTAssertEqual(SurfaceDisplay.parsePan("+1"), 1)
    }

    func testParsePanTrimsPadding() {
        XCTAssertEqual(SurfaceDisplay.parsePan("+63    "), 63)
        XCTAssertEqual(SurfaceDisplay.parsePan("  -1 "), -1)
    }

    func testParsePanGarbageIsNil() {
        XCTAssertNil(SurfaceDisplay.parsePan("Kick"))
        XCTAssertNil(SurfaceDisplay.parsePan(""))
        XCTAssertNil(SurfaceDisplay.parsePan("Pan/Su"))
    }

    // MARK: - isShowingTrackNames

    func testTrackNamesRowIsNames() {
        let top = row(["Kick", "Snare", "HiHat", "Toms", "OH", "Room", "Bass", "Guitar"])
        XCTAssertTrue(SurfaceDisplay.isShowingTrackNames(top))
    }

    func testPanSurroundHeaderIsNotNames() {
        var s = "Track 1 \"vox\"".padding(toLength: 44, withPad: " ", startingAt: 0)
        s += "Pan/Surround"
        XCTAssertFalse(SurfaceDisplay.isShowingTrackNames(s))
    }

    func testParameterHeaderIsNotNames() {
        let top = "vox    BacVox guitar bass   parameter: Pan".padding(toLength: 56, withPad: " ", startingAt: 0)
        XCTAssertFalse(SurfaceDisplay.isShowingTrackNames(top))
    }

    func testVolumeBannerIsNotNames() {
        // "Volume" occupies a 14-char field: cell 0 = "Volume", cell 1 blank.
        let top = fieldRow("Volume", atCell: 0)
        XCTAssertFalse(SurfaceDisplay.isShowingTrackNames(top))
    }

    func testTrackNumberHeaderIsNotNames() {
        let top = "Track 12".padding(toLength: 56, withPad: " ", startingAt: 0)
        XCTAssertFalse(SurfaceDisplay.isShowingTrackNames(top))
    }

    func testModalPanShapeIsNotNames() {
        let top = row(["Pan", "-", "-", "-", "-", "-", "-", "-"])
        XCTAssertFalse(SurfaceDisplay.isShowingTrackNames(top))
    }

    func testConservativeTrackNamedVolumeIsStillNames() {
        // A real track literally named "Volume" at channel 0, with a normal neighbor in
        // cell 1, must NOT be mistaken for the transient volume banner.
        let top = row(["Volume", "Snare", "HiHat", "Toms", "OH", "Room", "Bass", "Gtr"])
        XCTAssertTrue(SurfaceDisplay.isShowingTrackNames(top))
    }

    // MARK: - isPerChannelPan (axis 1: per-channel pan vs the dead single-parameter page)
    //
    // These reproduce the EXACT bottom-row shapes measured on real Logic via `lcdprobe`.
    // Per-channel pan paints a live parameter cell for every strip; the single-parameter
    // page paints ONE live cell (V-Pot 0) and "-" for the rest.

    func testSingleParameterPageIsNotPerChannelPan() {
        // Single-parameter page: only V-Pot 0 is live. "Pan  -  -  …".
        let bottom = row(["Pan", "-", "-", "-", "-", "-", "-", "-"])
        XCTAssertFalse(SurfaceDisplay.isPerChannelPan(bottom))
    }

    func testPerChannelPanNamesIsPerChannelPan() {
        // Per-channel pan, NAMES: "Pan  Pan  Pan  Pan  Pan  Pan  Pan  -".
        let bottom = row(["Pan", "Pan", "Pan", "Pan", "Pan", "Pan", "Pan", "-"])
        XCTAssertTrue(SurfaceDisplay.isPerChannelPan(bottom))
    }

    func testPerChannelPanValuesIsPerChannelPan() {
        // Per-channel pan, VALUES: "0  0  0  0  0  0  0  <blank>".
        let bottom = row(["0", "0", "0", "0", "0", "0", "0", ""])
        XCTAssertTrue(SurfaceDisplay.isPerChannelPan(bottom))
    }

    func testMixedSignedValuesIsPerChannelPan() {
        // Signed ints with a few "-" for strips that have no pan (e.g. Master).
        let bottom = row(["-64", "-30", "0", "+3", "+63", "-", "-", "-"])
        XCTAssertTrue(SurfaceDisplay.isPerChannelPan(bottom))
    }

    // MARK: - isShowingValues (axis 2: signed-integer VALUES vs "Pan" NAMES)

    func testValuesRowIsShowingValues() {
        let bottom = row(["0", "0", "0", "0", "0", "0", "0", ""])
        XCTAssertTrue(SurfaceDisplay.isShowingValues(bottom))
    }

    func testSignedValuesRowIsShowingValues() {
        let bottom = row(["-64", "-30", "0", "+3", "+63", "-", "-", "-"])
        XCTAssertTrue(SurfaceDisplay.isShowingValues(bottom))
    }

    func testNamesRowIsNotShowingValues() {
        // "Pan" cells are NAMES, not values — none parse as a signed integer.
        let bottom = row(["Pan", "Pan", "Pan", "Pan", "Pan", "Pan", "Pan", "-"])
        XCTAssertFalse(SurfaceDisplay.isShowingValues(bottom))
    }

    func testSingleParameterPageNamesIsNotShowingValues() {
        let bottom = row(["Pan", "-", "-", "-", "-", "-", "-", "-"])
        XCTAssertFalse(SurfaceDisplay.isShowingValues(bottom))
    }
}
