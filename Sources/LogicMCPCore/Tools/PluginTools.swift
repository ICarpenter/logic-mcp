import MCP

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

public struct GetPluginParamsTool: LogicTool {
    public let name = "get_plugin_params"
    public let description = "List a plugin's parameters (names and displayed values) from the MCU plugin-edit view. Names are the LCD's 7-char abbreviations. slot is the 0-based insert position."
    public let inputSchema = trackArgSchema(["slot": .object(["type": .string("integer")])], required: ["slot"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...7).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…7", layer: "daemon")
        }
        let (track, params) = try await enterPluginEdit(daemon, trackName: trackName, slot: slot)
        await exitPluginEdit(daemon)
        return .object([
            "track": .string(track.name),
            "slot": .int(slot),
            "params": .array(params.map { .object([
                "index": .int($0.index), "name": .string($0.name), "display": .string($0.display),
            ]) }),
        ])
    }
}

public struct SetPluginParamTool: LogicTool {
    public let name = "set_plugin_param"
    public let description = "Set one plugin parameter. param: LCD name (prefix ok) or integer index from get_plugin_params. value: normalized 0.0-1.0. Returns the display string Logic echoed."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("LCD param name or integer index")]),
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

        let (track, params) = try await enterPluginEdit(daemon, trackName: trackName, slot: slot)
        let wanted = paramKey.lowercased()
        let target = params.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in params.first { $0.index == i } }
        guard let target else {
            await exitPluginEdit(daemon)
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "mcu",
                              expected: "one of: \(params.map(\.name).joined(separator: ", "))",
                              observed: "no matching LCD cell")
        }

        // Page to the target's page, then delta the V-Pot: full sweep down, then up to value.
        for _ in 0..<target.page { await daemon.session.press(.channelRight) }
        await daemon.session.settle(.milliseconds(150))
        await daemon.session.turnVPot(channel: target.channel, ticks: -127)
        await daemon.session.turnVPot(channel: target.channel, ticks: Int((value * 20).rounded()))
        await daemon.session.settle(.milliseconds(150))

        let display = await daemon.session.surface
            .lcdCell(line: 1, channel: target.channel).trimmingCharacters(in: .whitespaces)
        await exitPluginEdit(daemon)
        guard !display.isEmpty else {
            throw ToolFailure(error: "parameter change not confirmed", layer: "mcu",
                              expected: "updated value in LCD cell \(target.channel)", observed: "blank cell")
        }
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_param", track: track.name,
            undoArguments: nil,
            descriptionText: "\(track.name) \(target.name) \(target.display) → \(display)"))
        return .object(["param": .string(target.name), "display": .string(display)])
    }
}
