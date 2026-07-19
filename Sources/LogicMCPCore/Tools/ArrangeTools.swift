import MCP

/// Resolve a named control-bar control or throw the standard "no arrange window / no control" error.
/// Shared by every arrange tool so the not-open-project path is identical everywhere.
func arrangeControl(_ daemon: Daemon, role: String, description: String, tool: String) async throws -> AXHandle {
    guard await daemon.ax.arrangeWindow() != nil else {
        throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                          expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
    }
    guard let control = await daemon.ax.controlBarControl(role: role, description: description) else {
        throw ToolFailure(error: "\(tool): control '\(description)' not found in the Control Bar", layer: "ax",
                          expected: "an \(role) description=\"\(description)\"", observed: "none")
    }
    return control
}

public struct SetTempoTool: LogicTool {
    public let name = "set_tempo"
    public let description = "Set the project tempo (BPM) via Logic's control bar, verified by re-reading the tempo. NOTE: this sets the tempo at the CURRENT playhead position — with the playhead at the start (or no tempo changes in the project) that is the project tempo. Editing a tempo map with multiple changes is a separate capability."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["bpm": .object(["type": .string("number"),
            "description": .string("Target tempo in beats per minute, e.g. 120 or 128.5")])]),
        "required": .array([.string("bpm")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard let bpm = args["bpm"]?.coercedDouble, bpm > 0 else {
            throw ToolFailure(error: "'bpm' must be a positive number", layer: "daemon")
        }
        let slider = try await arrangeControl(daemon, role: "AXSlider", description: "Tempo", tool: name)
        let (loO, hiO) = await daemon.ax.minMax(of: slider)
        // nudgeToRaw drives BOTH absolute and ±1-nudge sliders (Task 0): absolute reaches in one
        // AXSetValue, nudge in N. Cap steps to the slider's raw span so a nudge slider can still
        // traverse end-to-end; fall back to a generous cap if the range is unreadable.
        let steps = (loO != nil && hiO != nil && hiO! > loO!) ? Int((hiO! - loO!).rounded(.up)) + 2 : 2000
        let achieved = try await daemon.ax.nudgeToRaw(slider, target: bpm, maxSteps: steps)
        let verified = abs(achieved - bpm) <= 0.5
        return .object(["tempo": .double(achieved), "verified": .bool(verified)])
    }
}

/// Shared: select a choice in a named control-bar popup, verified against the popup's re-read value.
private func selectControlBarPopup(_ daemon: Daemon, description: String, choice: String, tool: String) async throws -> Value {
    let popup = try await arrangeControl(daemon, role: "AXPopUpButton", description: description, tool: tool)
    try await daemon.menu.selectEnumChoice(from: popup, choice: choice)   // throws layer:"ax" listing choices on a miss
    let now = await daemon.ax.stringValue(.value, of: popup) ?? ""
    let verified = now.range(of: choice, options: .caseInsensitive) != nil
        || choice.range(of: now, options: .caseInsensitive) != nil
    return .object(["display": .string(now), "verified": .bool(verified)])
}

public struct SetTimeSignatureTool: LogicTool {
    public let name = "set_time_signature"
    public let description = "Set the project time signature via Logic's control-bar popup (e.g. '4/4', '6/8'), verified against the popup's displayed value."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["signature": .object(["type": .string("string"),
            "description": .string("e.g. '4/4', '3/4', '6/8'")])]),
        "required": .array([.string("signature")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let sig = try requireString(args, "signature", tool: name)
        return try await selectControlBarPopup(daemon, description: "Time Signature", choice: sig, tool: name)
    }
}

public struct SetPlayheadTool: LogicTool {
    public let name = "set_playhead"
    public let description = "Move the playhead to a bar (and optional beat) via Logic's control bar, verified by re-reading the position. beat defaults to 1."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "bar": .object(["type": .string("integer"), "description": .string("Target bar (1-based)")]),
            "beat": .object(["type": .string("integer"), "description": .string("Target beat within the bar; defaults to 1")]),
        ]),
        "required": .array([.string("bar")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard let bar = args["bar"]?.coercedInt, bar >= 1 else {
            throw ToolFailure(error: "'bar' must be an integer ≥ 1", layer: "daemon")
        }
        let beat = args["beat"]?.coercedInt ?? 1
        guard beat >= 1 else { throw ToolFailure(error: "'beat' must be an integer ≥ 1", layer: "daemon") }

        guard await daemon.ax.arrangeWindow() != nil else {
            throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                              expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
        }
        guard let barS = await daemon.ax.controlBarControl(role: "AXSlider", description: "bar"),
              let beatS = await daemon.ax.controlBarControl(role: "AXSlider", description: "beat") else {
            throw ToolFailure(error: "playhead sliders not found in the Control Bar", layer: "ax",
                              expected: "AXSlider description=\"bar\" and \"beat\"", observed: "none")
        }
        let achievedBar = try await daemon.ax.nudgeToRaw(barS, target: Double(bar), maxSteps: 1200)
        let achievedBeat = try await daemon.ax.nudgeToRaw(beatS, target: Double(beat), maxSteps: 64)
        let verified = Int(achievedBar.rounded()) == bar && Int(achievedBeat.rounded()) == beat
        return .object(["bar": .int(Int(achievedBar.rounded())), "beat": .int(Int(achievedBeat.rounded())),
                        "verified": .bool(verified)])
    }
}

/// Press the named track's Has Focus radio and confirm — via a fresh re-read — that EXACTLY that
/// track is now focused. Returns true iff confirmed. Throws layer:"ax" (listing names) if the track
/// name is unknown. The delete/rename guard depends on this: never mutate on an unconfirmed selection.
func selectTrackConfirmed(_ daemon: Daemon, _ name: String) async throws -> Bool {
    guard await daemon.ax.arrangeWindow() != nil else {
        throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                          expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
    }
    let names = await daemon.ax.arrangeHeaderItems().map(\.name)
    guard let header = await daemon.ax.arrangeHeader(named: name), let focus = header.focus else {
        throw ToolFailure(error: "no track '\(name)' in the arrange headers", layer: "ax",
                          expected: "one of: \(names.joined(separator: ", "))", observed: "no match")
    }
    try await daemon.ax.press(focus)
    // Selection re-renders headers; re-read from a fresh walk (never the captured handle).
    let focused = await daemon.ax.focusedTrackNames()
    return focused.count == 1 && focused[0].caseInsensitiveCompare(name) == .orderedSame
}

public struct SelectTrackTool: LogicTool {
    public let name = "select_track"
    public let description = "Select (focus) a track by name in Logic's arrange area, via the track header's Has Focus control, confirmed by re-reading that exactly that track is focused. This is what makes delete_track safe. Case-insensitive."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let confirmed = try await selectTrackConfirmed(daemon, name)
        return .object(["selected": .string(name), "confirmed": .bool(confirmed)])
    }
}

public struct SetCycleTool: LogicTool {
    public let name = "set_cycle"
    public let description = "Enable or disable Logic's cycle (loop) mode, and optionally set its range by bar. 'enabled': turn cycle on/off (verified). 'startBar'/'endBar' (optional, together): set the cycle range; the range is set by moving the playhead to each bar and copying its timeline position to the locator (encoding-free)."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "enabled": .object(["type": .string("boolean")]),
            "startBar": .object(["type": .string("integer")]),
            "endBar": .object(["type": .string("integer")]),
        ]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        // Step 1 (up front, mutation-free): parse args and validate the range ARGS only — cheap
        // shape-checking, no AX handle resolution yet. Handles are resolved fresh, immediately
        // before use, in each block below — never captured here and reused past a mutation.
        let enabled = args["enabled"]?.boolValue
        let rangeRequested = args["startBar"] != nil || args["endBar"] != nil

        var s = 0, e = 0
        if rangeRequested {
            guard let sv = args["startBar"]?.coercedInt, let ev = args["endBar"]?.coercedInt,
                  sv >= 1, ev > sv else {
                throw ToolFailure(error: "set_cycle needs both startBar and endBar, with endBar > startBar", layer: "daemon")
            }
            s = sv; e = ev
        }

        guard enabled != nil || rangeRequested else {
            throw ToolFailure(error: "set_cycle needs 'enabled' and/or 'startBar'+'endBar'", layer: "daemon")
        }

        var result: [String: Value] = [:]

        // Step 2: range block FIRST — resolve every handle fresh and complete the whole range
        // mutation BEFORE the toggle press below. Pressing Cycle is itself a mutation; a handle
        // resolved earlier and used after it would be stale (CLAUDE.md "THE recurring bug class").
        // A bad/unsupported range fails here, before any toggle has been touched — atomicity preserved.
        if rangeRequested {
            guard let thumb = await daemon.ax.playheadThumb(),
                  let startM = await daemon.ax.cycleMarker("Start Marker"),
                  let endM = await daemon.ax.cycleMarker("End Marker"),
                  let barS = await daemon.ax.controlBarControl(role: "AXSlider", description: "bar"),
                  let beatS = await daemon.ax.controlBarControl(role: "AXSlider", description: "beat"),
                  await daemon.ax.isSettable(startM), await daemon.ax.isSettable(endM) else {
                throw ToolFailure(error: "cycle range-by-bar is not available on this Logic build", layer: "ax",
                                  expected: "settable Start/End Marker indicators and bar/beat sliders sharing the playhead-thumb encoding",
                                  observed: "markers or bar/beat sliders not settable/found — set the cycle range in Logic, or use 'enabled' only")
            }

            // Rosetta stone: move the playhead to a bar, read its encoded timeline position, and write
            // that raw to the marker — no need to decode Logic's internal tick unit.
            func rawForBar(_ bar: Int) async throws -> Double {
                _ = try await daemon.ax.nudgeToRaw(barS, target: Double(bar), maxSteps: 1200)
                // Also land on the bar's downbeat (beat 1) — mirrors SetPlayheadTool's bar+beat
                // pair — so a stale beat/tick offset from a prior position isn't carried into the
                // recorded raw.
                _ = try await daemon.ax.nudgeToRaw(beatS, target: 1, maxSteps: 64)
                return await daemon.ax.value(of: thumb) ?? 0
            }
            let rawStart = try await rawForBar(s)
            let rawEnd = try await rawForBar(e)
            // Markers are assumed absolute-set (the Rosetta approach requires it): one AXSetValue lands the raw, so a small step cap is correct here — NOT derived from the marker's own encoded range (~2e15), which would make maxSteps astronomically large and effectively hang; if a marker turns out non-absolute, rangeVerified below honestly reports false rather than looping.
            _ = try await daemon.ax.nudgeToRaw(startM, target: rawStart, maxSteps: 8)
            _ = try await daemon.ax.nudgeToRaw(endM, target: rawEnd, maxSteps: 8)
            let gotStart = await daemon.ax.value(of: startM) ?? 0
            let gotEnd = await daemon.ax.value(of: endM) ?? 0
            result["startBar"] = .int(s); result["endBar"] = .int(e)
            result["rangeVerified"] = .bool(abs(gotStart - rawStart) < 1 && abs(gotEnd - rawEnd) < 1)
        }

        // Step 3: enable-toggle block LAST — resolve the Cycle checkbox FRESH here, immediately
        // before pressing it, so it's never a handle carried across the range mutation above.
        if let enabled {
            let cycle = try await arrangeControl(daemon, role: "AXCheckBox", description: "Cycle", tool: name)
            let now = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
            if now != enabled { try await daemon.ax.press(cycle) }
            let after = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
            result["enabled"] = .bool(after)
        }

        return .object(result)
    }
}

public struct SetKeySignatureTool: LogicTool {
    public let name = "set_key_signature"
    public let description = "Set the project key signature via Logic's control-bar popup (e.g. 'C Major', 'A Minor'), verified against the popup's displayed value."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["key": .object(["type": .string("string"),
            "description": .string("e.g. 'C Major', 'A Minor', 'G Major'")])]),
        "required": .array([.string("key")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let key = try requireString(args, "key", tool: name)
        return try await selectControlBarPopup(daemon, description: "Key Signature", choice: key, tool: name)
    }
}
