import Foundation

/// Parses a Controls-view row's display string (Logic's human value, e.g. "15 %", "0.0 dB",
/// "Mono", "1/4") into a number + unit. The number is the verification oracle for a slider set;
/// enum-valued params (no leading number) parse to `number == nil`.
public enum PluginDisplay {
    public struct Parsed: Equatable, Sendable {
        public let number: Double?
        public let unit: String?
        public let raw: String
    }

    public static func parse(_ s: String) -> Parsed {
        let raw = s
        let str = s.trimmingCharacters(in: .whitespaces)
        // Leading signed decimal: optional '-', digits, optional '.digits'. A leading number that
        // is immediately followed by '/' (e.g. "1/4") is a fraction ENUM, not a scalar — reject.
        var idx = str.startIndex
        if idx < str.endIndex, str[idx] == "-" { idx = str.index(after: idx) }
        var sawDigit = false
        while idx < str.endIndex, str[idx].isNumber { idx = str.index(after: idx); sawDigit = true }
        if idx < str.endIndex, str[idx] == "." {
            idx = str.index(after: idx)
            while idx < str.endIndex, str[idx].isNumber { idx = str.index(after: idx); sawDigit = true }
        }
        guard sawDigit, !(idx < str.endIndex && str[idx] == "/") else {
            return Parsed(number: nil, unit: nil, raw: raw)
        }
        let numStr = String(str[str.startIndex..<idx])
        let unit = String(str[idx...]).trimmingCharacters(in: .whitespaces)
        return Parsed(number: Double(numStr), unit: unit, raw: raw)
    }
}
