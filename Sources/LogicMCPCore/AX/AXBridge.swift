import Foundation

/// The AX analog of `MCUSession`: locate the mixer surface and read/write channel strips
/// by full track name. All AX access is confined to this actor. NEVER activates Logic.
public actor AXBridge {
    private let p: AXProvider
    public init(provider: AXProvider) { self.p = provider }

    /// Depth-first search for the `AXLayoutArea desc="Mixer"` under any window.
    private func mixerArea() throws -> AXHandle {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 8 { return nil }
            if p.string(.role, of: h) == "AXLayoutArea", p.string(.description, of: h) == "Mixer" { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        for w in p.windows() { if let a = rec(w, 0) { return a } }
        throw ToolFailure(error: "no mixer surface", layer: "ax",
                          expected: "an open Mixer window or pane",
                          observed: "no AXLayoutArea \"Mixer\" in any window — open the Mixer (View ▸ Show Mixer)")
    }

    public func stripHandles() throws -> [(name: String, handle: AXHandle)] {
        let area = try mixerArea()
        return p.children(of: area)
            .filter { p.string(.role, of: $0) == "AXLayoutItem" }
            .compactMap { h in p.string(.description, of: h).map { (name: $0, handle: h) } }
    }

    public func find(_ name: String) throws -> AXHandle {
        let strips = try stripHandles()
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = strips.filter { $0.name.lowercased() == wanted }
        if exact.count == 1 { return exact[0].handle }
        let known = strips.map(\.name).joined(separator: ", ")
        if exact.count > 1 {
            throw ToolFailure(error: "ambiguous track name '\(name)'", layer: "ax",
                              expected: "a unique strip", observed: known)
        }
        let prefix = strips.filter { $0.name.lowercased().hasPrefix(wanted) }
        if prefix.count == 1 { return prefix[0].handle }
        throw ToolFailure(error: prefix.isEmpty ? "no track named '\(name)'" : "ambiguous track name '\(name)'",
                          layer: "ax", expected: "one of the mixer strips", observed: known)
    }

    public func control(_ strip: AXHandle, description: String) -> AXHandle? {
        p.children(of: strip).first { p.string(.description, of: $0) == description }
    }
    /// Recursive descendant search by role and/or description — used where a control lives
    /// deeper than a strip's immediate children (send groups, plugin windows).
    public func descendant(of h: AXHandle, role: String? = nil, description: String? = nil) -> AXHandle? {
        func rec(_ x: AXHandle, _ d: Int) -> AXHandle? {
            if d > 10 { return nil }
            let rOK = role == nil || p.string(.role, of: x) == role
            let dOK = description == nil || p.string(.description, of: x) == description
            if (role != nil || description != nil), rOK, dOK { return x }
            for c in p.children(of: x) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.children(of: h).lazy.compactMap { rec($0, 0) }.first
    }
    /// The output-routing button has a dynamic description (the bus name), so it is found
    /// by exclusion: the AXButton whose description is none of the fixed control labels.
    private func outputButton(_ strip: AXHandle) -> AXHandle? {
        let fixed: Set<String> = ["mute", "solo", "send button", "audio plug-in", "MIDI plug-in",
                                  "insert bar", "EQ", "group", "volume fader level", "peak level meter"]
        return p.children(of: strip).first {
            p.string(.role, of: $0) == "AXButton"
                && !(p.string(.description, of: $0).map(fixed.contains) ?? true)
        }
    }

    public func read(_ strip: AXHandle) -> AXStripControls {
        let name = p.string(.description, of: strip) ?? ""
        var db: Double?; var silent = false
        if let title = control(strip, description: "volume fader level").flatMap({ p.string(.title, of: $0) }),
           let parsed = AXStrip.parseDB(title) { db = parsed.db; silent = parsed.silent }
        let mute = (control(strip, description: "mute").flatMap { p.string(.value, of: $0) }) == "on"
        let solo = (control(strip, description: "solo").flatMap { p.string(.value, of: $0) }) == "on"
        let pan = control(strip, description: "pan").flatMap { p.number(of: $0) }.map { Int($0.rounded()) }
        let output = outputButton(strip).flatMap { p.string(.description, of: $0) }
        return AXStripControls(name: name, volumeDB: db, volumeSilent: silent,
                               pan: pan, mute: mute, solo: solo, output: output)
    }

    public func value(of h: AXHandle) -> Double? { p.number(of: h) }
    public func stringValue(_ attr: AXAttr, of h: AXHandle) -> String? { p.string(attr, of: h) }
    public func isSettable(_ h: AXHandle) -> Bool { p.isSettable(h) }
    public func setValue(_ v: Double, of h: AXHandle) throws { try p.setNumber(v, of: h) }
    public func press(_ h: AXHandle) throws { try p.perform(.press, on: h) }
    public func step(_ up: Bool, _ h: AXHandle) throws { try p.perform(up ? .increment : .decrement, on: h) }
    public func titleOfLevel(_ strip: AXHandle) -> String? {
        control(strip, description: "volume fader level").flatMap { p.string(.title, of: $0) }
    }
    public func minMax(of h: AXHandle) -> (Double?, Double?) { p.minMax(of: h) }

    /// Converge a slider on `target` by repeated nudging. AXSetValue on Logic sliders moves
    /// ONE unit toward the target per call (see ax-findings.md), so this loops until the
    /// read-back reaches `target` or stops progressing. Returns the achieved raw value.
    public func nudgeToRaw(_ h: AXHandle, target: Double, maxSteps: Int) throws -> Double {
        var last = p.number(of: h) ?? 0
        if last == target { return last }
        for _ in 0..<maxSteps {
            try p.setNumber(target, of: h)          // moves 1 toward target
            let now = p.number(of: h) ?? last
            if now == target || now == last { return now }   // reached, or stuck at a boundary
            last = now
        }
        return last
    }
}
