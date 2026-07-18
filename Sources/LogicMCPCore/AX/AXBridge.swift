import Foundation

/// The AX analog of `MCUSession`: locate the mixer surface and read/write channel strips
/// by full track name. All AX access is confined to this actor. NEVER activates Logic.
public actor AXBridge {
    private let p: AXProvider
    public init(provider: AXProvider) { self.p = provider }

    /// The `AXLayoutArea desc="Mixer"` of Logic's MIXER WINDOW — bind-or-throw, never degrade.
    ///
    /// BUG 2 (real Logic, 2026-07-14): the arrange window's Inspector contains a MINI-MIXER with
    /// the SAME role+description, showing only the selected track's strip (+ its output). With
    /// the Mixer WINDOW closed it is the only `AXLayoutArea "Mixer"` left, so the old search bound
    /// it and `refresh_state` returned 2 strips REPORTING SUCCESS — silently REPLACING the shadow
    /// model (the real project's tracks vanished from it, and since every mixer tool addresses
    /// tracks BY NAME, lookups then missed or hit the wrong strip). The old "pick the area with
    /// the most AXLayoutItems" heuristic does not catch that case at all: with one candidate, the
    /// mini-mixer IS the max.
    ///
    /// So: only ever bind a mixer area whose containing WINDOW is titled "…Mixer…"
    /// (`"Untitled 1 - Mixer: Tracks"`, vs the arrange window's `"Untitled 1 - Tracks"` — see
    /// Fixtures/ax/strip_special.txt). If there is none, THROW; the caller
    /// (`Daemon.ensureMixerWindow()`) self-heals by pressing `Window ▸ Open Mixer` and retrying.
    /// The most-strips tiebreak is kept for the pathological case of a PROJECT whose name itself
    /// contains "Mixer" (then the arrange window's title matches too, and the real mixer still
    /// wins on strip count).
    private func mixerArea() throws -> AXHandle {
        let areas = mixerAreas()
        if areas.count == 1 { return areas[0] }   // the normal case
        guard let best = areas.max(by: { stripCount($0) < stripCount($1) }) else {
            throw ToolFailure(error: "no mixer surface", layer: "ax",
                              expected: "an open Mixer window",
                              observed: "no AXLayoutArea \"Mixer\" inside a window titled \"…Mixer…\" — open the Mixer (Window ▸ Open Mixer / ⌘2). The arrange window's Inspector mini-mixer is deliberately NOT used: it shows only the selected track and would corrupt the shadow model.")
        }
        return best
    }

    /// Mixer layout areas that live inside a window whose TITLE contains "Mixer" — i.e. the real
    /// Mixer window ("Untitled 1 - Mixer: Tracks"), never the arrange window ("Untitled 1 -
    /// Tracks") whose Inspector holds a mini-mixer with the identical role+description.
    private func mixerAreas() -> [AXHandle] {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 8 { return nil }
            if p.string(.role, of: h) == "AXLayoutArea", p.string(.description, of: h) == "Mixer" { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.windows()
            .filter { (p.string(.title, of: $0) ?? "").localizedCaseInsensitiveContains("Mixer") }
            .compactMap { rec($0, 0) }
    }

    private func stripCount(_ area: AXHandle) -> Int {
        p.children(of: area).filter { p.string(.role, of: $0) == "AXLayoutItem" }.count
    }

    /// Is Logic's Mixer WINDOW open? (i.e. does a window whose title contains "Mixer" hold a
    /// mixer layout area). The arrange window's Inspector mini-mixer does NOT count. The
    /// no-focus oracle for `Daemon.ensureMixerWindow()`, which presses `Window ▸ Open Mixer`
    /// when this is false and settle-polls it back to true.
    public func hasMixerWindow() -> Bool {
        !mixerAreas().isEmpty
    }

    /// A strip's TRUE track name. The `AXLayoutItem` description is UNRELIABLE — a strip scrolled
    /// off-screen returns a numeric placeholder ("88 1 4") there instead of the name (real Logic,
    /// 2026-07-15, mcp_test.logicx: vox / Aux 1 / Stereo Out / Master all came back garbage, and
    /// name-addressing missed them — `get_track("Stereo Out")` → "no track named 'Stereo Out'").
    /// The child `AXTextField description="name"` carries the real name for EVERY strip, on- or
    /// off-screen, so read that; fall back to the layout-item description only if it's absent.
    private func stripName(_ strip: AXHandle) -> String? {
        if let field = control(strip, description: "name"),
           let v = p.string(.value, of: field), !v.isEmpty { return v }
        return p.string(.description, of: strip)
    }

    public func stripHandles() throws -> [(name: String, handle: AXHandle)] {
        let area = try mixerArea()
        return p.children(of: area)
            .filter { p.string(.role, of: $0) == "AXLayoutItem" }
            .compactMap { h in stripName(h).map { (name: $0, handle: h) } }
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
    /// Test-only: enumerate windows (mirrors the provider) so unit tests can grab a plugin window
    /// handle without a full Daemon. Safe: read-only.
    func windowsForTest() -> [AXHandle] { p.windows() }
    func titleForTest(_ h: AXHandle) -> String? { p.string(.title, of: h) }
    /// Test-only: the provider's root, or its first window if the provider has no distinct root
    /// (mirrors `windowsForTest`) — lets a converger test build a bare slider+display pair without
    /// a full mixer/window tree.
    func rootForTest() -> AXHandle { (try? p.root()) ?? p.windows()[0] }
    /// Test-only: resolve the AXSlider and its sibling AXGroup display among `h`'s children —
    /// the minimal shape `AXConvergerTests` builds directly, without a full Controls-view table.
    func childHandlesForTest(of h: AXHandle) -> (slider: AXHandle, display: AXHandle) {
        let kids = p.children(of: h)
        let slider = kids.first { p.string(.role, of: $0) == "AXSlider" }!
        let display = kids.first { p.string(.role, of: $0) == "AXGroup" }!
        return (slider, display)
    }
    func titleForViewMenuTest(_ window: AXHandle) -> String? {
        descendant(of: window, role: "AXMenuButton", description: "view").flatMap { p.string(.title, of: $0) }
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
    /// The fixed control labels a strip's children carry (Fixtures/ax/mixer_strip.txt +
    /// strip_special.txt). Only a NEGATIVE guard on the structural match below — never the
    /// primary discriminator.
    private static let fixedStripLabels: Set<String> = [
        "name", "mute", "solo", "volume fader", "fader knob", "volume fader level",
        "peak level meter", "pan", "knob readout", "automation", "list", "group",
        "send button", "audio plug-in", "MIDI plug-in", "insert bar", "channel mode",
        "EQ", "gain reduction meter", "setting", "bypass", "open",
        "bounce", "dim", "mastering assistant", "add aux", "record",
    ]

    /// The strip's output-routing slot, or nil if the strip HAS NO OUTPUT SLOT.
    ///
    /// BUG 1 (real Logic, 2026-07-14): this used to find the slot by EXCLUSION — the first
    /// AXButton whose description isn't a known fixed label — because the routing button's
    /// description is dynamic (it IS the current destination: "Bus 21", "Stereo Output"). But
    /// `Stereo Out` and `Master` have NO routing button at all, so exclusion matched an unrelated
    /// mixer-panel button: live, `Stereo Out` reported its output as "bounce" and `Master` as
    /// "dim" (both AXSwitches). That corrupted `refresh_state`'s `output` field and handed
    /// `set_output` a random button to press.
    ///
    /// Identify it POSITIVELY instead, anchored STRUCTURALLY: the routing slot is the IMMEDIATE
    /// NEXT SIBLING of the `AXPopUpButton description="group"`, accepted only if it is a plain
    /// AXButton with no subrole, no value, and a description that isn't a fixed control label.
    /// If that check fails there is no output slot — return nil and let the caller say so. A
    /// wrong answer is worse than no answer.
    ///
    /// NOT a name-shape match (`Bus \d+`, …): buses are RENAMABLE in Logic, so any such regex
    /// breaks on a custom bus name. The structural anchor is the robust discriminator.
    /// See Fixtures/ax/strip_special.txt (normal / SI / aux / Stereo Out / Master).
    private func outputButton(_ strip: AXHandle) -> AXHandle? {
        let kids = p.children(of: strip)
        guard let groupIdx = kids.firstIndex(where: {
            p.string(.role, of: $0) == "AXPopUpButton" && p.string(.description, of: $0) == "group"
        }) else { return nil }                                  // no "group" anchor ⇒ no slot
        let next = kids.index(after: groupIdx)
        guard next < kids.endIndex else { return nil }          // "group" was last ⇒ no slot
        let candidate = kids[next]
        guard p.string(.role, of: candidate) == "AXButton",     // a plain button…
              p.string(.subrole, of: candidate) == nil,         // …not an AXSwitch ("bounce"/"dim")
              p.string(.value, of: candidate) == nil,           // …and it carries no value
              let desc = p.string(.description, of: candidate), !desc.isEmpty,
              !Self.fixedStripLabels.contains(desc)             // …nor a fixed label ("audio plug-in")
        else { return nil }
        return candidate
    }

    /// Public passthrough to `outputButton(_:)` for `set_output`. nil means the strip has no
    /// output slot (Stereo Out, Master) — the caller MUST refuse, not fall back to another button.
    public func outputButtonHandle(_ strip: AXHandle) -> AXHandle? { outputButton(strip) }

    public func read(_ strip: AXHandle) -> AXStripControls {
        let name = stripName(strip) ?? ""
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

    /// Re-reads `h`'s numeric AX value; if it comes back equal to `prior` (looks like no
    /// movement happened), don't trust that on the first read — poll briefly instead.
    /// `AXUIElementSetAttributeValue` updates a slider's value ASYNCHRONOUSLY on real Logic: an
    /// immediate re-read right after a write can return the STALE pre-write value, which is
    /// indistinguishable from a genuine "stuck at a boundary" without this confirmation step
    /// (real-Logic smoke: `set_volume db:-0.2` converged from -4.1 and bailed at -1.1 dB because
    /// a post-nudge read came back stale and looked stuck). Polls every 30ms for up to ~200ms;
    /// if the value still hasn't changed from `prior` by then, it's genuinely stuck. Shared by
    /// `nudgeToRaw` below and `axConvergeVolume` (MixTools.swift) so both stuck-detections use
    /// the same settle-confirmed read. The extra latency is only paid when a nudge already LOOKS
    /// stuck (rare) — a normal converging nudge returns on the first read, same cost as before.
    public func settledValue(of h: AXHandle, unlessChangedFrom prior: Double?) async -> Double? {
        var now = p.number(of: h)
        if now != prior { return now }
        let deadline = ContinuousClock.now + .milliseconds(200)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
            now = p.number(of: h)
            if now != prior { return now }
        }
        return now   // unchanged even after the settle window ⇒ genuinely stuck
    }

    /// Converge a slider on `target` by repeated nudging. AXSetValue on Logic sliders moves
    /// ONE unit toward the target per call (see ax-findings.md), so this loops until the
    /// read-back reaches `target` or stops progressing. Returns the achieved raw value.
    public func nudgeToRaw(_ h: AXHandle, target: Double, maxSteps: Int) async throws -> Double {
        var last = p.number(of: h) ?? 0
        if last == target { return last }
        for _ in 0..<maxSteps {
            try p.setNumber(target, of: h)          // moves 1 toward target
            let now = await settledValue(of: h, unlessChangedFrom: last) ?? last
            if now == target || now == last { return now }   // reached, or settle-confirmed stuck
            last = now
        }
        return last
    }

    /// Plugin slots on a strip are AXGroups (e.g. "Channel EQ", "RetroSyn") each with an
    /// "open" child button (see Fixtures/ax/mixer_strip.txt). Returns them in tree order so
    /// `slot` indexes them; the dedicated Channel EQ group is included like any other.
    public func pluginGroups(_ strip: AXHandle) -> [(name: String, group: AXHandle)] {
        p.children(of: strip).compactMap { g in
            guard p.string(.role, of: g) == "AXGroup",
                  let name = p.string(.description, of: g), !name.isEmpty,
                  p.children(of: g).contains(where: { p.string(.description, of: $0) == "open" })
            else { return nil }
            return (name, g)
        }
    }
    /// A plugin window is an AXWindow whose title is the TRACK name and which has both a `close`
    /// button and a `view` menu (distinguishes it from the mixer window, also track-titled
    /// sometimes). NOT an `AXSlider` requirement — opaque plugins (Editor view with no exposed
    /// sliders) have none, and would otherwise go undetected (see
    /// `testPluginWindowDetectsOpaqueWindow`).
    public func pluginWindow(track: String) -> AXHandle? {
        p.windows().first {
            (p.string(.title, of: $0) ?? "") == track
                && descendant(of: $0, role: nil, description: "close") != nil
                && descendant(of: $0, role: "AXMenuButton", description: "view") != nil
        }
    }

    /// Switch a plugin window to Logic's generic "Controls" view. No-op if already there. The
    /// `view` control is an AXMenuButton (description="view"); its title reflects the current view.
    /// close-then-open reverts to Editor, so tools call this on every open before reading the table.
    public func switchToControlsView(_ window: AXHandle) async throws {
        guard let viewMenu = descendant(of: window, role: "AXMenuButton", description: "view") else {
            throw ToolFailure(error: "no view switcher on this plugin window", layer: "ax",
                              expected: "an AXMenuButton description=\"view\"", observed: "none")
        }
        if p.string(.title, of: viewMenu) == "Controls" { return }
        try? p.perform(.press, on: viewMenu)                 // open the menu
        try? await Task.sleep(for: .milliseconds(40))
        let items = p.children(of: viewMenu).flatMap { c -> [AXHandle] in
            p.string(.role, of: c) == "AXMenu" ? p.children(of: c) : []
        }
        guard let controls = items.first(where: { p.string(.title, of: $0) == "Controls" }) else {
            // Dismiss the still-open view AXMenu before throwing — otherwise a failed lookup
            // leaves Logic's UI with a dangling open menu (same "clean up before throw"
            // convention as `restorePanBeforeThrow` in PluginTools.swift).
            try? p.perform(.cancel, on: viewMenu)
            throw ToolFailure(error: "no 'Controls' view for this plugin", layer: "ax",
                              expected: "a 'Controls' menu item", observed:
                                "available: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
        }
        try p.perform(.press, on: controls)
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Close every currently-open plugin window for `track`, so a following open deterministically
    /// lands on the REQUESTED slot instead of reusing whatever window happens to already be up.
    /// `pluginWindow(track:)` matches only on window TITLE == track name, so with more than one
    /// slot's window open (e.g. slot 0's window left open from an earlier call), it can return the
    /// wrong slot's params — confirmed live (`get_plugin_params(slot:1)` returned slot 0's Channel
    /// EQ). Loops because more than one window can be open on the same track; capped at 8 to avoid
    /// spinning forever if a window won't close. A brief pause after each press lets the AX tree
    /// settle before the next lookup.
    public func closePluginWindows(track: String) async {
        for _ in 0..<8 {
            guard let window = pluginWindow(track: track) else { return }
            guard let closeBtn = descendant(of: window, role: "AXButton", description: "close") else { return }
            try? press(closeBtn)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
    /// How a Controls-view slider actually moves under AX — SELECTED BY THE TASK 0 LIVE PROBE.
    /// `.absolute`: AXSetValue lands the raw at the requested value → converge by binary search.
    /// `.step`: only AXIncrement/AXDecrement move it, by a fixed amount → converge by linear stepping.
    public enum SliderActuation: Sendable { case absolute, step }

    /// The default the tools pass. TASK 0 PROVED `.absolute`: on the vox Channel EQ Low Shelf Gain,
    /// AXSetValue is absolute + linear (raw 0→−24 dB, 240→0 dB, 480→+24 dB). `.step` (AXIncrement/
    /// AXDecrement, ±24 raw/step here) is implemented and tested as a fallback but is NOT the default —
    /// it is too coarse to hit fine unit targets. See ax-findings.md 2026-07-17.
    public static let defaultSliderActuation: SliderActuation = .absolute

    /// Converge `slider` until the number parsed from `display` reaches `target` (±`tolerance`), using
    /// the probe-proven `actuation`. The DISPLAY STRING is the sole oracle; the raw value is only a
    /// search coordinate (never assume a raw↔unit curve — the display may be nonlinear or inverse).
    /// Returns the achieved display number, or nil if the display is unreadable. Never fabricates: an
    /// unreachable target returns the nearest achieved value (the caller reports verified:false).
    public func convergeAdaptive(slider: AXHandle, display: AXHandle, target: Double,
                                 tolerance: Double, actuation: SliderActuation,
                                 maxSteps: Int) async throws -> Double? {
        func disp() -> Double? { PluginDisplay.parse(p.string(.value, of: display) ?? "").number }
        switch actuation {
        case .absolute:
            let (loO, hiO) = p.minMax(of: slider)
            guard let lo = loO, let hi = hiO, hi > lo else { return nil }
            return try await convergeByBisection(slider: slider, disp: disp, lo: lo, hi: hi,
                                                 target: target, tolerance: tolerance)
        case .step:
            return try await convergeByStepping(slider: slider, disp: disp,
                                                target: target, tolerance: tolerance, maxSteps: maxSteps)
        }
    }

    /// Binary-search the raw against the display oracle. Establishes polarity by sampling the display
    /// at the two rails (the display may rise OR fall with raw), then bisects toward `target`. ~40
    /// bisections cover any practical raw range. Reads the display only after the raw SETTLES
    /// (`settledValue`) — an immediate post-write read can be stale (ax-findings.md).
    private func convergeByBisection(slider: AXHandle, disp: () -> Double?, lo: Double, hi: Double,
                                     target: Double, tolerance: Double) async throws -> Double? {
        // Seed against the real pre-write raw, not nil — settledValue's "now != prior" check is
        // vacuously true when prior is nil, so it would return immediately without polling and
        // dLo could be read stale on Logic's async writes (review fix).
        let before0 = p.number(of: slider)
        try p.setNumber(lo, of: slider); _ = await settledValue(of: slider, unlessChangedFrom: before0)
        guard let dLo = disp() else { return nil }
        try p.setNumber(hi, of: slider); _ = await settledValue(of: slider, unlessChangedFrom: lo)
        guard let dHi = disp() else { return nil }
        let ascending = dHi >= dLo                       // does a higher raw yield a higher display?
        var loR = lo, hiR = hi
        var best = disp()
        for _ in 0..<40 {
            let mid = (loR + hiR) / 2
            let before = p.number(of: slider)
            try p.setNumber(mid, of: slider)
            _ = await settledValue(of: slider, unlessChangedFrom: before)
            guard let d = disp() else { return best }
            best = d
            if abs(d - target) <= tolerance { return d }
            // Move toward the rail that pushes the display toward target, honoring polarity.
            if (target > d) == ascending { loR = mid } else { hiR = mid }
            if hiR - loR < 1 { break }                   // raw resolution exhausted → nearest is best
        }
        return best
    }

    /// Step-converge via AXIncrement/AXDecrement. One probe increment establishes the display polarity,
    /// then steps toward `target`, re-reading the display each step. Bails honestly when the raw stops
    /// moving (a genuine boundary) — settle-confirmed so an async-stale read isn't mistaken for stuck.
    private func convergeByStepping(slider: AXHandle, disp: () -> Double?, target: Double,
                                    tolerance: Double, maxSteps: Int) async throws -> Double? {
        guard let start = disp() else { return nil }
        let before = p.number(of: slider)
        try p.perform(.increment, on: slider)
        _ = await settledValue(of: slider, unlessChangedFrom: before)
        guard var cur = disp() else { return nil }
        let ascending = cur >= start                     // did the display rise on one increment?
        for _ in 0..<maxSteps {
            if abs(cur - target) <= tolerance { return cur }
            let up = (target > cur) == ascending
            let rawBefore = p.number(of: slider)
            try p.perform(up ? .increment : .decrement, on: slider)
            let settled = await settledValue(of: slider, unlessChangedFrom: rawBefore)
            if settled == nil || settled == rawBefore { return disp() }   // settle-confirmed stuck
            guard let now = disp() else { return cur }
            cur = now
        }
        return disp()
    }

    /// Walk a Controls-view plugin window's AXTable into typed rows. Returns [] if there is no
    /// table (an opaque plugin, or a window still in Editor view). Name comes from the cell's
    /// AXStaticText (trailing ':' trimmed); display from the sibling AXGroup (sliders) or the
    /// control's own value (toggle/popup).
    public func controlTable(in window: AXHandle) -> [PluginControl] {
        guard let table = descendant(of: window, role: "AXTable", description: nil) else { return [] }
        var out: [PluginControl] = []
        for row in p.children(of: table) where p.string(.role, of: row) == "AXRow" {
            guard let cell = p.children(of: row).first(where: { p.string(.role, of: $0) == "AXCell" })
            else { continue }
            let kids = p.children(of: cell)
            guard let label = kids.first(where: { p.string(.role, of: $0) == "AXStaticText" }),
                  var name = p.string(.value, of: label), !name.isEmpty else { continue }
            if name.hasSuffix(":") { name.removeLast() }
            guard let control = kids.first(where: {
                ["AXSlider", "AXCheckBox", "AXPopUpButton"].contains(p.string(.role, of: $0) ?? "")
            }) else { continue }
            let role = p.string(.role, of: control)
            let kind: PluginControl.Kind = role == "AXPopUpButton" ? .popup
                : (role == "AXCheckBox" ? .toggle : .slider)
            let group = kids.first(where: { p.string(.role, of: $0) == "AXGroup" })
            let display = kind == .slider ? group.flatMap { p.string(.value, of: $0) }
                                          : p.string(.value, of: control)
            out.append(PluginControl(index: out.count, name: name, kind: kind, display: display,
                                     choices: nil, settable: p.isSettable(control),
                                     handle: control, displayHandle: kind == .slider ? group : nil))
        }
        return out
    }

    /// Poll `controlTable(in:)` until it yields rows or a ~1s deadline — the Controls-view AXTable
    /// populates ASYNCHRONOUSLY after `switchToControlsView` (real Logic, 2026-07-17: get_plugin_params
    /// intermittently returned opaque:true because a single-shot read beat the populate). Returns [] only
    /// if still empty after the deadline (a genuinely opaque plugin). Same settle discipline as
    /// `settledValue`; the cost is paid only when the table looks empty (rare).
    public func settledControlTable(in window: AXHandle) async -> [PluginControl] {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            let rows = controlTable(in: window)
            if !rows.isEmpty || ContinuousClock.now >= deadline { return rows }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
