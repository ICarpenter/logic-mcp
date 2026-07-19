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

public struct SelectTrackTool: LogicTool {
    public let name = "select_track"
    public let description = "DISABLED — track selection is not available via Accessibility in this release. Always returns a structured error and never presses anything."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        throw ToolFailure(error: "track selection is not available via Accessibility", layer: "ax",
                          expected: "n/a — AX cannot set Logic's track selection",
                          observed: "the arrange header's Has Focus control is a read-only status indicator; AXPress on it (and on the track header / name field) is a no-op (Task 0 live probe, ax-findings.md)")
    }
}

public struct SetCycleTool: LogicTool {
    public let name = "set_cycle"
    public let description = "Enable or disable Logic's cycle (loop) mode, verified by re-reading the Cycle control. (Setting the cycle RANGE by bar is not available via AX — the locators are drag-only.)"
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "enabled": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("enabled")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard let enabled = args["enabled"]?.boolValue else {
            throw ToolFailure(error: "set_cycle requires 'enabled' (true/false)", layer: "daemon")
        }
        let cycle = try await arrangeControl(daemon, role: "AXCheckBox", description: "Cycle", tool: name)
        let now = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
        if now != enabled { try await daemon.ax.press(cycle) }
        let after = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
        return .object(["enabled": .bool(after)])
    }
}

public struct GetArrangeStateTool: LogicTool {
    public let name = "get_arrange_state"
    public let description = "Read the arrange control bar live via Accessibility: tempo, time signature, key signature, playhead (bar/beat), and whether cycle is on. Touches Logic (unlike get_project_overview)."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard await daemon.ax.arrangeWindow() != nil else {
            throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                              expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
        }
        func num(_ desc: String) async -> Double? {
            guard let h = await daemon.ax.controlBarControl(role: "AXSlider", description: desc) else { return nil }
            return await daemon.ax.value(of: h)
        }
        func popup(_ desc: String) async -> String? {
            guard let h = await daemon.ax.controlBarControl(role: "AXPopUpButton", description: desc) else { return nil }
            return await daemon.ax.stringValue(.value, of: h)
        }
        var obj: [String: Value] = [:]
        if let cycleCtl = await daemon.ax.controlBarControl(role: "AXCheckBox", description: "Cycle") {
            obj["cycling"] = .bool((await daemon.ax.stringValue(.value, of: cycleCtl)) == "1")
        }
        if let t = await num("Tempo") { obj["tempo"] = .double(t) }
        if let ts = await popup("Time Signature") { obj["timeSignature"] = .string(ts) }
        if let ks = await popup("Key Signature") { obj["keySignature"] = .string(ks) }
        if let b = await num("bar"), let be = await num("beat") {
            obj["playhead"] = .object(["bar": .int(Int(b.rounded())), "beat": .int(Int(be.rounded()))])
        }
        let focused = await daemon.ax.focusedTrackNames()
        if focused.count == 1 { obj["selectedTrack"] = .string(focused[0]) }
        return .object(obj)
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
