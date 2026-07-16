import MCP

// MARK: - Retired MCU plugin path (Task 10)
//
// `enterPluginEdit`/`exitPluginEdit`/`restorePanBeforeThrow` below are the DANGEROUS MCU
// plugin-edit path described in HANDOFF.md's "one dangerous bug": they press
// `.select(channel:)` then `.assignPlugin` then `.vpotPress(slot)`, settling blind between
// each. Logic's plugin view follows the SELECTED track, and selection does not always land
// before the next press, so this path could (and did, live) read or WRITE the wrong track's
// plugin — including fabricating params for an empty slot instead of throwing.
//
// This code is kept for historical reference only. Nothing in this file calls it anymore;
// `GetPluginParamsTool`/`SetPluginParamTool` below go through `axEnterPluginControls`, which
// never selects a track, never touches the MCU wire, and cannot race.

struct PluginParamCell: Sendable {
    var index: Int
    var name: String
    var display: String
    var page: Int
    var channel: Int
}

/// Restore the pan view before throwing, so a failed lookup doesn't leave the
/// surface stuck in a plugin view (same convention as SendTools.swift's restoreMode()).
///
/// The press switches the V-Pot assignment away from PLUGIN; `normalizeSurface()` then
/// OBSERVES where it landed and corrects it. The press alone is not enough: `.assignPan`
/// is a toggle, so if the surface was already in pan it flips into the single-parameter
/// page where every V-Pot but the first is dead.
private func restorePanBeforeThrow(_ daemon: Daemon) async {
    await daemon.session.press(.assignPan)
    await daemon.session.settle(.milliseconds(150))
    try? await daemon.navigator.normalizeSurface()
}

func enterPluginEdit(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (track: TrackState, params: [PluginParamCell]) {
    let (track, channel) = try await resolveAndBank(daemon, track: trackName)
    await daemon.session.press(.select(channel: channel))
    await daemon.session.press(.assignPlugin)
    await daemon.session.settle(.milliseconds(150))

    // We are now in the plugin-SELECT view. Capture its LCD so we can tell
    // whether pressing vpotPress(slot) actually entered plugin-EDIT mode:
    // FakeLogic (and real Logic) silently no-ops that press when the slot is
    // empty, which would otherwise let a stale, non-blank select-view LCD
    // ("ChanEQ" from slot 0, say) get misread as slot `slot`'s params below.
    let selectView = await daemon.session.surface.lcdTop
    await daemon.session.press(.vpotPress(channel: slot))
    await daemon.session.settle(.milliseconds(150))
    let afterView = await daemon.session.surface.lcdTop
    if afterView == selectView {
        await restorePanBeforeThrow(daemon)
        throw ToolFailure(error: "no plugin in slot \(slot) on '\(track.name)'", layer: "mcu",
                          expected: "a plugin in slot \(slot)", observed: selectView)
    }

    var params: [PluginParamCell] = []
    var page = 0
    while page < 16 {   // hard cap: 128 params
        let surface = await daemon.session.surface
        for ch in 0..<8 {
            let name = surface.lcdCell(line: 0, channel: ch).trimmingCharacters(in: .whitespaces)
            let display = surface.lcdCell(line: 1, channel: ch).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                params.append(PluginParamCell(index: page * 8 + ch, name: name,
                                              display: display, page: page, channel: ch))
            }
        }
        let before = surface.lcdTop
        await daemon.session.press(.channelRight)
        await daemon.session.settle(.milliseconds(150))
        if await daemon.session.surface.lcdTop == before { break }   // last page
        page += 1
    }
    if params.isEmpty {
        await restorePanBeforeThrow(daemon)
        throw ToolFailure(error: "no plugin parameters visible", layer: "mcu",
                          expected: "plugin edit LCD for '\(trackName)' slot \(slot)",
                          observed: "blank LCD — is a plugin loaded in that slot?")
    }
    // Return to page 0 so a following set targets the right cells.
    for _ in 0..<page { await daemon.session.press(.channelLeft) }
    await daemon.session.settle(.milliseconds(150))
    return (track, params)
}

/// Leave plugin edit and restore the pan view all other tools assume.
/// Press to leave PLUGIN, then normalize — see `restorePanBeforeThrow` for why the
/// press alone cannot be trusted.
func exitPluginEdit(_ daemon: Daemon) async {
    await daemon.session.press(.assignPan)
    await daemon.session.settle(.milliseconds(150))
    try? await daemon.navigator.normalizeSurface()
}

// MARK: - AX plugin path (Task 10) — the only path the tools call

/// Open the slot's plugin window via AX, switch it to Controls view, and return its parameter
/// rows. No MCU, no track selection, no wrong-track race. Empty `controls` == opaque plugin.
func axEnterPluginControls(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (name: String, window: AXHandle, controls: [PluginControl]) {
    let strip = try await daemon.mixerStrip(named: trackName)
    let name = await daemon.ax.read(strip).name
    let groups = await daemon.ax.pluginGroups(strip)
    guard slot >= 0, slot < groups.count else {
        throw ToolFailure(error: "no plugin in slot \(slot) on '\(name)'", layer: "ax",
                          expected: "one of \(groups.count) plugin slots: \(groups.map(\.name).joined(separator: ", "))",
                          observed: "slot \(slot) out of range")
    }
    // Close every open window for this track first (windows key only on track title), then open
    // the REQUESTED slot deterministically — same discipline as before.
    await daemon.ax.closePluginWindows(track: name)
    if let openBtn = await daemon.ax.descendant(of: groups[slot].group, role: "AXButton", description: "open") {
        try? await daemon.ax.press(openBtn)
    }
    guard let window = await daemon.ax.pluginWindow(track: name) else {
        throw ToolFailure(error: "could not open plugin '\(groups[slot].name)' on '\(name)'", layer: "ax",
                          expected: "an open plugin window titled '\(name)'", observed: "no plugin window")
    }
    try await daemon.ax.switchToControlsView(window)
    let controls = await daemon.ax.controlTable(in: window)
    return (name, window, controls)
}

public struct GetPluginParamsTool: LogicTool {
    public let name = "get_plugin_params"
    public let description = "List a plugin's parameters (names, kinds, displayed values) from Logic's generic Controls view, read via Accessibility. Works for Apple and third-party plugins. slot is the 0-based index into the strip's plugin groups in tree order. 'opaque':true means the plugin exposes no addressable parameters."
    public let inputSchema = trackArgSchema(["slot": .object(["type": .string("integer")])], required: ["slot"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        let params: [Value] = controls.map { c in
            .object(["index": .int(c.index), "name": .string(c.name), "kind": .string(c.kind.rawValue),
                     "display": .string(c.display ?? ""), "settable": .bool(c.settable)])
        }
        return .object(["track": .string(name), "slot": .int(slot),
                        "opaque": .bool(controls.isEmpty), "params": .array(params)])
    }
}

public struct SetPluginParamTool: LogicTool {
    public let name = "set_plugin_param"
    public let description = "Set one plugin parameter via Logic's Controls view, verified against the parameter's displayed value. 'param': name (prefix ok) or integer index from get_plugin_params. 'value': a normalized number 0.0–1.0, OR a string with units matching the display (e.g. '-6 dB', '25 %'). Returns the display string Logic echoed and whether it verified."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("Parameter name (prefix ok) or integer index")]),
        "value": .object(["description": .string("Normalized 0–1 number, or a unit string like '-6 dB'")]),
    ], required: ["slot", "param", "value"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.coercedInt.map(String.init)
        guard let paramKey else { throw ToolFailure(error: "missing required argument 'param'", layer: "daemon") }

        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        let sliders = controls.filter { $0.kind == .slider }
        let wanted = paramKey.lowercased()
        let target = sliders.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in (0..<sliders.count).contains(i) ? sliders[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "ax",
                              expected: sliders.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard target.settable, let displayHandle = target.displayHandle else {
            throw ToolFailure(error: "parameter '\(target.name)' is not a settable slider", layer: "ax",
                              expected: "a settable slider with a display", observed: "not settable")
        }

        // Both convergence paths nudge ±1 raw unit per AXSetValue call (ax-findings.md), so the
        // step budget must scale with the slider's actual raw range — a flat cap (e.g. 600)
        // can't reach a far target on a wide-range slider (a 0…10000 raw Bass % control needs up
        // to 10000 nudges to traverse end to end).
        let (loO, hiO) = await daemon.ax.minMax(of: target.handle)
        guard let lo = loO, let hi = hiO, hi > lo else {
            throw ToolFailure(error: "parameter '\(target.name)' has no readable range", layer: "ax",
                              expected: "AXMinValue/AXMaxValue", observed: "missing range")
        }
        let steps = Int((hi - lo).rounded(.up)) + 2

        var verified = false
        if let unitStr = args["value"]?.stringValue, PluginDisplay.parse(unitStr).number != nil {
            // Unit target: converge against the display-string oracle.
            let goal = PluginDisplay.parse(unitStr).number!
            let achieved = try await daemon.ax.convergeToDisplay(
                slider: target.handle, display: displayHandle, target: goal, tolerance: 0.5, maxSteps: steps)
            verified = achieved.map { abs($0 - goal) <= 0.5 } ?? false
        } else if let norm = args["value"]?.coercedDouble, (0.0...1.0).contains(norm) {
            // Normalized target: map onto the slider's raw range and nudge there.
            let rawTarget = lo + norm * (hi - lo)
            let achieved = try await daemon.ax.nudgeToRaw(target.handle, target: rawTarget, maxSteps: steps)
            verified = abs(achieved - rawTarget) <= 1
        } else {
            throw ToolFailure(error: "'value' must be a 0.0–1.0 number or a unit string like '-6 dB'",
                              layer: "daemon")
        }

        let display = await daemon.ax.stringValue(.value, of: displayHandle) ?? ""
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_param", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(display)"))
        return .object(["param": .string(target.name), "display": .string(display), "verified": .bool(verified)])
    }
}
