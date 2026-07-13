import Foundation

/// Reads the numbers Logic PRINTS on the surface LCD, turning displayed text into
/// ground truth. Logic never sends dB or pan over the MCU wire — it only paints them on
/// the LCD — so `set_volume`/`set_pan` read them back here instead of trusting a curve.
///
/// All formats below were MEASURED on real Logic via `logic-mcp lcdprobe`:
///   • Volume (transient, ~2s, only while a fader is touched): TOP row "Volume", BOTTOM
///     row the dB value ("-9.0 dB", "+0.0 dB", "-119 dB", "-oo dB"), in a 14-char (2-cell)
///     field. Channel 7 has no cell 8 to spill into, so the field shifts LEFT to cells 6+7.
///   • Pan (continuous, one signed integer per channel on the BOTTOM row): "-64" … "+63".
public enum SurfaceDisplay {
    /// The touched channel's 2-cell (14-char) value field. For channels 0…6 it starts at
    /// the channel's own cell; channel 7 shares cells 6+7 with channel 6 (`min(channel, 6)`).
    public static func valueText(_ surface: SurfaceState, line: Int, channel: Int) -> String {
        let pair = min(channel, 6)
        return (surface.lcdCell(line: line, channel: pair) + surface.lcdCell(line: line, channel: pair + 1))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse Logic's dB banner. The double-optional distinguishes THREE outcomes the
    /// caller must not conflate:
    ///   • `.some(.some(db))` — a real dB value was read (e.g. "-9.0 dB").
    ///   • `.some(.none)`     — a recognized SILENT reading ("-oo dB"): the fader is at -∞.
    ///   • `.none`            — unparseable (not a dB banner at all); caller should fall back.
    /// (The reference `Calibrate.parseDB` collapsed the last two into one `nil`; this must not.)
    public static func parseDB(_ text: String) -> Double?? {
        let cleaned = text.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return .none }                                   // no banner present
        if cleaned.contains("oo") || cleaned.contains("∞") { return .some(nil) }   // "-oo dB": silent
        if let value = Double(cleaned.replacingOccurrences(of: "+", with: "")) { return .some(value) }
        return .none                                                          // unparseable
    }

    /// Parse a signed pan integer ("-64" … "+63"), stripping a leading '+'. `nil` when the
    /// cell holds something else (a track name, a "-" placeholder, blank).
    public static func parsePan(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        return Int(cleaned)
    }

    /// AXIS 1 — is the bottom row showing PER-CHANNEL pan (one live parameter per strip),
    /// as opposed to the dead SINGLE-PARAMETER page (only V-Pot 0 is live, the rest are "-")?
    ///
    /// Measured on real Logic: per-channel pan paints a live cell for every strip that has a
    /// pan ("Pan  Pan  …" in names mode, "0  -30  +3  …" in values mode); the single-parameter
    /// page paints exactly ONE live cell and "-" for the other seven. A cell is "live" when it
    /// is neither the "-" placeholder nor blank. At least 2 live cells ⇒ per-channel pan.
    public static func isPerChannelPan(_ bottom: String) -> Bool {
        rowCells(bottom).filter { !$0.isEmpty && $0 != "-" }.count >= 2
    }

    /// AXIS 2 — within per-channel pan, is the bottom row showing signed-integer VALUES
    /// ("0", "-30", "+63") rather than the "Pan" parameter NAMES? True when at least one
    /// live (non-"-", non-blank) cell parses as a signed pan integer via `parsePan`. The
    /// names row's live cells all read "Pan", which `parsePan` rejects, so this is false there.
    public static func isShowingValues(_ bottom: String) -> Bool {
        rowCells(bottom).contains { !$0.isEmpty && $0 != "-" && parsePan($0) != nil }
    }

    /// True when the top LCD row is the normal track-name row, false when it is a
    /// parameter/assignment view (which `enumerateTracks` must NEVER read as names).
    ///
    /// Markers observed on real Logic: a `Pan/Surround` header, a `parameter:` header, the
    /// transient `Volume` banner, a `Track N` assignment header, or the modal
    /// `Pan   -   -   …` shape. Each check is conservative — a track could legitimately be
    /// named "Volume", so that marker also requires the banner's tell-tale blank second cell.
    public static func isShowingTrackNames(_ top: String) -> Bool {
        if top.contains("Pan/Surround") { return false }
        if top.contains("parameter:") { return false }

        let cells = rowCells(top)

        // Modal assignment shape: cell 0 is an assignment label, cells 1…7 are all "-".
        let assignmentLabels: Set<String> = ["Pan", "Volume", "Send", "Sends", "EQ",
                                             "Inst", "Plug-In", "Track", "I/O"]
        if assignmentLabels.contains(cells[0]), cells.dropFirst().allSatisfy({ $0 == "-" }) {
            return false
        }

        // "Track 1", "Track 12", … — an assignment/parameter header, not a track name.
        if top.hasPrefix("Track "),
           let after = top.dropFirst("Track ".count).first, after.isNumber {
            return false
        }

        // Transient volume banner: "Volume" fills a 14-char field, leaving cell 1 blank.
        // Requiring cell 1 blank keeps a real track named "Volume" (with a neighbor in
        // cell 1) classified as names.
        if cells[0] == "Volume", cells[1].isEmpty {
            return false
        }

        return true
    }

    /// A row's eight 7-char cells, trimmed. Defensive against short/long rows.
    private static func rowCells(_ row: String) -> [String] {
        let padded = Array(row.padding(toLength: 56, withPad: " ", startingAt: 0))
        return (0..<8).map { i in
            String(padded[(i * 7)..<(i * 7 + 7)]).trimmingCharacters(in: .whitespaces)
        }
    }
}
