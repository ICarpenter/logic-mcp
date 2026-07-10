/// Maps the MCU fader's 14-bit position to Logic's dB scale (-∞ … +6 dB).
///
/// Anchors were MEASURED from a live Logic Pro fader sweep via `logic-mcp calibrate`:
/// each `raw` is the value Logic ECHOED back (Logic snaps every requested position onto
/// its own internal grid, so e.g. request 8192 echoes 8178) and each `db` is what Logic
/// printed on the surface LCD. Two independent sweeps agreed on every repeated point, and
/// the curve was identical on an audio track and on `St Out`, so one table serves all strips.
///
/// Two structural facts the naive 0…16383 stretch got wrong:
///   • Logic SATURATES at raw 14845 = +6.0 dB. Requests of 15360 and 16383 both echo 14845,
///     so any position at/above 14845 is +6.0 (never the ~3.7 dB a linear stretch reported).
///   • Silence (-∞) extends up to raw 7 (echo 7 → Logic shows "-oo dB"; echo 15 → "-138 dB").
public enum FaderCurve {
    /// Positions at or below this raw read as -∞ (Logic shows "-oo dB"): `dB(fromRaw:)` is nil.
    public static let silenceCeilingRaw = 7
    /// The fader tops out here: Logic clamps every higher request to this echoed position.
    public static let saturationRaw = 14845
    /// The dB value at (and above) `saturationRaw`.
    public static let saturationDB = 6.0

    // (raw, dB) — measured, strictly increasing in both columns. The taper has genuine
    // knees near raw 192 (slope drops ~10x) and raw 7800 (slope halves); those anchors are
    // real piecewise breakpoints, not noise — do not thin or smooth them.
    //
    // Density was chosen by HOLD-OUT validation: sample raws that fall between anchors and
    // compare against Logic. The 4600…6100 stretch and the 159…192 knee were resampled
    // because they showed the only residuals above 0.1 dB (worst was raw 5364: we said
    // -20.1, Logic says -19.7). Everything now agrees with Logic to within 0.1 dB, which is
    // the resolution of Logic's own display — see `logic-mcp calibrate`.
    static let anchors: [(raw: Int, db: Double)] = [
        (15, -138.0), (31, -132.0), (48, -126.0), (62, -120.0), (96, -107.0),
        (127, -94.7), (159, -82.4), (174, -76.6), (192, -70.0), (223, -68.8),
        (255, -67.6), (382, -62.8), (504, -59.5), (637, -58.1), (766, -56.9),
        (1022, -54.7), (1276, -52.0), (1531, -49.3), (2047, -44.8), (2552, -40.1),
        (3058, -35.0), (3583, -32.4), (4092, -29.2), (4604, -25.4), (4693, -24.8),
        (4842, -23.8), (4995, -22.6), (5110, -21.6), (5144, -21.3), (5247, -20.4),
        (5364, -19.7), (5485, -19.2), (5628, -18.6), (5748, -18.1), (5893, -17.5),
        (6038, -16.9), (6135, -16.5), (6635, -14.3), (7154, -12.1), (7411, -10.9),
        (7660, -9.9), (7892, -9.5), (8178, -9.0), (8403, -8.6), (8683, -8.1),
        (9186, -7.2), (9699, -6.3), (10220, -5.4), (10729, -4.3), (11248, -3.0),
        (11766, -1.7), (12283, -0.4), (12443, 0.0), (12765, 0.8), (13290, 2.1),
        (13815, 3.4), (14299, 4.6), (14576, 5.3), (14845, 6.0),
    ]

    /// True when `raw` sits at or below the silence ceiling — the fader is at -∞ (muted-quiet).
    /// Callers should ask this instead of hardcoding a comparison against a magic raw value.
    public static func isSilent(raw: Int) -> Bool {
        raw <= silenceCeilingRaw
    }

    public static func dB(fromRaw raw: Int) -> Double? {
        if isSilent(raw: raw) { return nil }
        if raw >= saturationRaw { return saturationDB }
        if raw <= anchors[0].raw { return anchors[0].db }
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if raw <= upper.raw {
                let t = Double(raw - lower.raw) / Double(upper.raw - lower.raw)
                let db = lower.db + t * (upper.db - lower.db)
                return (db * 10).rounded() / 10
            }
            lower = upper
        }
        return saturationDB
    }

    public static func raw(fromDB db: Double) -> Int {
        if db >= saturationDB { return saturationRaw }
        if db < anchors[0].db { return 0 }
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if db <= upper.db {
                let t = (db - lower.db) / (upper.db - lower.db)
                return lower.raw + Int((t * Double(upper.raw - lower.raw)).rounded())
            }
            lower = upper
        }
        return saturationRaw
    }
}
