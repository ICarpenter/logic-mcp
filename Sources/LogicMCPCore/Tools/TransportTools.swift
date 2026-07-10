import MCP

func transportValue(_ t: TransportState) -> Value {
    .object(["playing": .bool(t.playing), "recording": .bool(t.recording), "cycling": .bool(t.cycling)])
}

/// Press a transport button, verify via LED echo, update the model.
func pressTransport(_ daemon: Daemon, button: MCUButton, expectLED: MCUButton, expectState: LEDState,
                    mutate: @escaping @Sendable (inout TransportState) -> Void) async throws -> Value {
    // Open the event subscription BEFORE pressing — `events()` is live-only, so an `async let`
    // that subscribes after the press can miss an echo Logic delivers before it registers.
    let stream = await daemon.session.events()
    await daemon.session.press(button)
    let led = await MCUSession.first(of: stream, timeout: .seconds(1)) {
        if case .led(let b, let s) = $0 { return b == expectLED && s == expectState } else { return false }
    }
    guard led != nil else {
        throw ToolFailure(error: "transport button not confirmed", layer: "mcu",
                          expected: "LED \(expectLED) → \(expectState)", observed: "no LED echo within 1s")
    }
    await daemon.model.setTransport(mutate)
    return await transportValue(daemon.model.snapshot.transport)
}

let emptySchema: Value = .object(["type": .string("object"), "properties": .object([:])])

public struct PlayTool: LogicTool {
    public let name = "play"
    public let description = "Start playback. Verified by Logic's play-LED echo."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        try await pressTransport(daemon, button: .play, expectLED: .play, expectState: .on) {
            $0.playing = true
        }
    }
}

public struct StopTool: LogicTool {
    public let name = "stop"
    public let description = "Stop playback (and recording). Verified by the stop-LED echo."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        try await pressTransport(daemon, button: .stop, expectLED: .stop, expectState: .on) {
            $0.playing = false
            $0.recording = false
        }
    }
}

public struct ToggleCycleTool: LogicTool {
    public let name = "toggle_cycle"
    public let description = "Toggle cycle (loop) mode. Returns the new transport state."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let currentlyCycling = await daemon.model.snapshot.transport.cycling
        return try await pressTransport(daemon, button: .cycle, expectLED: .cycle,
                                        expectState: currentlyCycling ? .off : .on) {
            $0.cycling.toggle()
        }
    }
}

public struct RecordTool: LogicTool {
    public let name = "record"
    public let description = "Start recording. NEVER call this unless the user explicitly asked to record in their most recent request. Requires confirm: true."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["confirm": .object([
            "type": .string("boolean"),
            "description": .string("Must be true; asserts the user explicitly requested recording."),
        ])]),
        "required": .array([.string("confirm")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard args["confirm"]?.boolValue == true else {
            throw ToolFailure(error: "record requires confirm: true — only pass it when the user explicitly asked to record", layer: "daemon")
        }
        return try await pressTransport(daemon, button: .record, expectLED: .record, expectState: .on) {
            $0.recording = true
            $0.playing = true
        }
    }
}
