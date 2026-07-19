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
