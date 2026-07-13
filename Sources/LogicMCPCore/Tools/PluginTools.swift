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
// `GetPluginParamsTool`/`SetPluginParamTool` below go through `axEnterPlugin`, which never
// selects a track, never touches the MCU wire, and cannot race.

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

/// Open (if needed) the plugin at `slot` on `track` via AX and return the plugin window's
/// parameter controls. No MCU, no track selection, no wrong-track race. Throws a structured
/// error if the strip/slot has no addressable plugin window.
func axEnterPlugin(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (name: String, window: AXHandle, params: [(name: String, handle: AXHandle)]) {
    let strip = try await daemon.ax.find(trackName)
    let name = await daemon.ax.read(strip).name
    let groups = await daemon.ax.pluginGroups(strip)
    guard slot >= 0, slot < groups.count else {
        throw ToolFailure(error: "no plugin in slot \(slot) on '\(name)'", layer: "ax",
                          expected: "one of \(groups.count) plugin slots: \(groups.map(\.name).joined(separator: ", "))",
                          observed: "slot \(slot) out of range")
    }
    // Close every plugin window already open for this track FIRST, then deterministically open
    // the REQUESTED slot. `pluginWindow(track:)` matches only on window TITLE == track name, so
    // leaving another slot's window open (e.g. from a prior get_plugin_params call) made this
    // return the WRONG slot's params — confirmed live: get_plugin_params(slot:1) returned slot
    // 0's Channel EQ because slot 0's window was still up. Unconditional close-then-open removes
    // the ambiguity: after this, at most one plugin window for `name` can exist.
    await daemon.ax.closePluginWindows(track: name)
    if let openBtn = await daemon.ax.descendant(of: groups[slot].group, role: "AXButton", description: "open") {
        try? await daemon.ax.press(openBtn)
    }
    guard let window = await daemon.ax.pluginWindow(track: name) else {
        throw ToolFailure(error: "could not open plugin '\(groups[slot].name)' on '\(name)'", layer: "ax",
                          expected: "an open plugin window titled '\(name)'", observed: "no plugin window")
    }
    let params = await daemon.ax.paramControls(in: window)
    guard !params.isEmpty else {
        throw ToolFailure(error: "plugin parameters not accessible via AX", layer: "ax",
                          expected: "addressable parameter sliders", observed: "opaque plugin view")
    }
    return (name, window, params)
}

public struct GetPluginParamsTool: LogicTool {
    public let name = "get_plugin_params"
    public let description = "List a plugin's parameters (names and displayed values), read via Accessibility from the plugin's own window. slot is the 0-based index into the strip's plugin groups (Channel EQ, inserts...) in tree order."
    public let inputSchema = trackArgSchema(["slot": .object(["type": .string("integer")])], required: ["slot"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...7).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…7", layer: "daemon")
        }
        let (name, _, params) = try await axEnterPlugin(daemon, trackName: trackName, slot: slot)
        var out: [Value] = []
        for (i, param) in params.enumerated() {
            // `??` chains its RHS as a non-async autoclosure, so each side must be awaited
            // into a local binding first — an inline `await` inside `??` fails to compile.
            let title = await daemon.ax.stringValue(.title, of: param.handle)
            let numeric = await daemon.ax.value(of: param.handle)
            let display = title ?? numeric.map { String($0) } ?? ""
            out.append(.object(["index": .int(i), "name": .string(param.name), "display": .string(display)]))
        }
        return .object(["track": .string(name), "slot": .int(slot), "params": .array(out)])
    }
}

public struct SetPluginParamTool: LogicTool {
    public let name = "set_plugin_param"
    public let description = "Set one plugin parameter, converged via Accessibility on the plugin's own window. param: parameter name (prefix ok) or integer index from get_plugin_params. value: normalized 0.0-1.0, mapped onto the control's real engineering range. Returns the display string Logic echoed."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("Parameter name (prefix ok) or integer index")]),
        "value": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)]),
    ], required: ["slot", "param", "value"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...7).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…7", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.coercedInt.map(String.init)
        guard let paramKey else {
            throw ToolFailure(error: "missing required argument 'param'", layer: "daemon")
        }
        guard let value = args["value"]?.coercedDouble, (0.0...1.0).contains(value) else {
            throw ToolFailure(error: "'value' must be a number in 0.0…1.0", layer: "daemon")
        }

        let (name, _, params) = try await axEnterPlugin(daemon, trackName: trackName, slot: slot)
        let wanted = paramKey.lowercased()
        let target = params.first { $0.name.lowercased().hasPrefix(wanted) }
            // Bounds-checked both ways: `Int("-1")` must fall through to the "no match"
            // error below, never trap on a negative array subscript.
            ?? Int(paramKey).flatMap { i in (0..<params.count).contains(i) ? params[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "ax",
                              expected: params.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard await daemon.ax.isSettable(target.handle) else {
            throw ToolFailure(error: "parameter '\(target.name)' not settable via AX", layer: "ax",
                              expected: "a settable control", observed: "read-only")
        }
        // Param values are raw engineering units in [min,max]; the contract's `value` is 0…1.
        // Map, then converge by nudging (AXSetValue moves ±1 per call — ax-findings.md).
        let (loOpt, hiOpt) = await daemon.ax.minMax(of: target.handle)
        guard let lo = loOpt, let hi = hiOpt, hi > lo else {
            throw ToolFailure(error: "parameter '\(target.name)' has no readable range", layer: "ax",
                              expected: "AXMinValue/AXMaxValue on the slider", observed: "missing range")
        }
        let rawTarget = lo + value * (hi - lo)
        let steps = Int((hi - lo).rounded(.up)) + 2
        _ = try await daemon.ax.nudgeToRaw(target.handle, target: rawTarget, maxSteps: steps)
        let title = await daemon.ax.stringValue(.title, of: target.handle)
        let numeric = await daemon.ax.value(of: target.handle)
        let display = title ?? numeric.map { String($0) } ?? ""
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_param", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(display)"))
        return .object(["param": .string(target.name), "display": .string(display)])
    }
}
