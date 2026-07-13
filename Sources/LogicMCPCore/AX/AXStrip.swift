import Foundation

public struct AXStripControls: Sendable {
    public var name: String
    public var volumeDB: Double?
    public var volumeSilent: Bool
    public var pan: Int?
    public var mute: Bool
    public var solo: Bool
    public var output: String?
}

public enum AXStrip {
    /// Parse Logic's fader-level title, e.g. "volume fader level, -6.0 dB". Returns nil if
    /// the string is not a fader-level title. `db == nil && silent == true` means -∞.
    /// NOTE: confirm the exact silence glyph against `Fixtures/ax/mixer_strip.txt` (Task 2);
    /// Logic renders it "-∞ dB". Accept "-∞", "-inf", or the word "Off" to be safe.
    public static func parseDB(_ title: String) -> (db: Double?, silent: Bool)? {
        let lower = title.lowercased()
        guard lower.contains("db") || title.contains("∞") else { return nil }
        if !lower.contains("volume fader level") && !title.contains("∞") {
            // Only fader-level titles carry ", N dB"; guard against "peak level meter" etc.
            if !lower.contains("fader level") { return nil }
        }
        if title.contains("∞") || lower.contains("-inf") { return (nil, true) }
        // Grab the number just before "dB".
        let scanner = Scanner(string: title)
        let allowed = CharacterSet(charactersIn: "+-0123456789.")
        _ = scanner.scanUpToCharacters(from: allowed)
        guard let n = scanner.scanDouble() else { return nil }
        return (n, false)
    }
}
