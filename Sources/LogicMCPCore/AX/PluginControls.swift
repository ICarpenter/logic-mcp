import Foundation

/// One row of Logic's generic "Controls" view: a named parameter with its display value and
/// the settable AX control behind it. `handle` is re-resolved every call — never persisted.
public struct PluginControl: Sendable {
    public enum Kind: String, Sendable { case slider, toggle, popup }
    public let index: Int
    public let name: String
    public let kind: Kind
    public let display: String?         // the row's AXGroup value string ("15 %", "0.0 dB", "Off")
    public let choices: [String]?       // enum choices (nil in Plan 1 — populated by set_plugin_option)
    public let settable: Bool
    public let handle: AXHandle         // the AXSlider / AXCheckBox / AXPopUpButton
    public let displayHandle: AXHandle? // the sibling AXGroup carrying the live display (sliders)
}
