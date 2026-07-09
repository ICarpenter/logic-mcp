/// Maps the MCU fader's 14-bit position to Logic's dB scale (-∞ … +6 dB).
/// v0 anchors; recalibrated from a captured fader sweep in Task 16.
public enum FaderCurve {
    // (raw, dB) — strictly increasing in both columns. raw 0 is -∞ (returned as nil).
    static let anchors: [(raw: Int, db: Double)] = [
        (1, -96.0),
        (256, -72.0),
        (1024, -54.0),
        (2560, -42.0),
        (4096, -30.0),
        (6144, -21.0),
        (8192, -12.0),
        (10240, -6.0),
        (12288, 0.0),
        (14336, 3.0),
        (16383, 6.0),
    ]

    public static func dB(fromRaw raw: Int) -> Double? {
        if raw <= 0 { return nil }
        let clamped = min(raw, 16383)
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if clamped <= upper.raw {
                let t = Double(clamped - lower.raw) / Double(upper.raw - lower.raw)
                let db = lower.db + t * (upper.db - lower.db)
                return (db * 10).rounded() / 10
            }
            lower = upper
        }
        return 6.0
    }

    public static func raw(fromDB db: Double) -> Int {
        if db <= anchors[0].db { return 0 }
        if db >= 6.0 { return 16383 }
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if db <= upper.db {
                let t = (db - lower.db) / (upper.db - lower.db)
                return lower.raw + Int((t * Double(upper.raw - lower.raw)).rounded())
            }
            lower = upper
        }
        return 16383
    }
}
