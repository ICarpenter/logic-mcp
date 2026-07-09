import MCP

/// Resolve a track by name and bank the MCU window to show it. Every mix tool starts here.
func resolveAndBank(_ daemon: Daemon, track name: String) async throws -> (track: TrackState, channel: Int) {
    let track = try await daemon.navigator.resolve(name)
    let channel = try await daemon.navigator.bank(toShow: track.index)
    // Re-read: banking refreshed volumeRaw in the model.
    let fresh = try await daemon.model.track(named: track.name)
    return (fresh, channel)
}

func trackArgSchema(_ extra: [String: Value], required: [String]) -> Value {
    var properties: [String: Value] = ["track": .object([
        "type": .string("string"), "description": .string("Track name (case-insensitive; unique prefix ok)"),
    ])]
    for (key, value) in extra { properties[key] = value }
    return .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array((["track"] + required).map { .string($0) }),
    ])
}

public struct SetVolumeTool: LogicTool {
    public let name = "set_volume"
    public let description = "Set a track's volume fader. Pass exactly one of: db (absolute, -∞ as -100 … +6.0) or delta (relative dB). Returns the dB value Logic echoed back — ground truth, not the requested value."
    public let inputSchema = trackArgSchema([
        "db": .object(["type": .string("number")]),
        "delta": .object(["type": .string("number")]),
    ], required: [])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let db = args["db"]?.doubleValue
        let delta = args["delta"]?.doubleValue
        guard (db == nil) != (delta == nil) else {
            throw ToolFailure(error: "set_volume needs exactly one of 'db' or 'delta'", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)

        let targetDB: Double
        if let db {
            targetDB = db
        } else {
            guard let currentRaw = track.volumeRaw, let currentDB = FaderCurve.dB(fromRaw: currentRaw) else {
                throw ToolFailure(error: "current volume unknown; cannot apply delta", layer: "model",
                                  expected: "an observed fader position for '\(track.name)'",
                                  observed: "none — run refresh_state and retry")
            }
            targetDB = currentDB + delta!
        }

        let echoedRaw = try await daemon.session.moveFader(
            channel: channel, toRaw: FaderCurve.raw(fromDB: targetDB), timeout: .seconds(1))
        let echoedDB = FaderCurve.dB(fromRaw: echoedRaw)
        await daemon.model.updateTrack(index: track.index) {
            $0.volumeRaw = echoedRaw
            $0.volumeDB = echoedDB
            $0.volumeIsSilent = echoedRaw == 0
        }
        let priorDB = track.volumeDB
        await daemon.journal.record(MixMutation(
            tool: "set_volume", track: track.name,
            undoArguments: priorDB.map { ["track": track.name, "db": String($0)] },
            descriptionText: "\(track.name) volume \(priorDB.map { String($0) } ?? "-∞") → \(echoedDB.map { String($0) } ?? "-∞") dB"))
        return .object([
            "track": .string(track.name),
            "volumeDB": echoedDB.map { Value.double($0) } ?? .null,
            "volumeRaw": .int(echoedRaw),
        ])
    }
}

/// Mute and solo share the toggle-until-LED-matches shape.
func setToggle(_ daemon: Daemon, trackName: String, on: Bool,
               button: @escaping @Sendable (Int) -> MCUButton,
               read: @escaping @Sendable (TrackState) -> Bool,
               write: @escaping @Sendable (inout TrackState, Bool) -> Void,
               label: String) async throws -> Value {
    let (track, channel) = try await resolveAndBank(daemon, track: trackName)
    let prior = read(track)
    let current = await daemon.session.surface.leds[button(channel)] == .on
    if current != on {
        async let led = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .led(let b, let s) = $0 { return b == button(channel) && s == (on ? .on : .off) }
            return false
        }
        await daemon.session.press(button(channel))
        guard await led != nil else {
            throw ToolFailure(error: "\(label) not confirmed", layer: "mcu",
                              expected: "\(label) LED \(on ? "on" : "off") for '\(track.name)'",
                              observed: "no LED echo within 1s")
        }
    }
    await daemon.journal.record(MixMutation(
        tool: label.contains("mute") ? "set_mute" : "set_solo", track: track.name,
        undoArguments: ["track": track.name, "on": prior ? "true" : "false"],
        descriptionText: "\(track.name) \(label) \(prior) → \(on)"))
    await daemon.model.updateTrack(index: track.index) { write(&$0, on) }
    return .object(["track": .string(track.name), label.contains("mute") ? "mute" : "solo": .bool(on)])
}

public struct SetMuteTool: LogicTool {
    public let name = "set_mute"
    public let description = "Mute or unmute a track. Idempotent; verified by Logic's mute-LED echo."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggle(daemon, trackName: trackName, on: on,
                                   button: { .mute(channel: $0) },
                                   read: { $0.mute }, write: { $0.mute = $1 }, label: "mute")
    }
}

public struct SetSoloTool: LogicTool {
    public let name = "set_solo"
    public let description = "Solo or unsolo a track. Idempotent; verified by Logic's solo-LED echo."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggle(daemon, trackName: trackName, on: on,
                                   button: { .solo(channel: $0) },
                                   read: { $0.solo }, write: { $0.solo = $1 }, label: "solo")
    }
}

public struct SetPanTool: LogicTool {
    public let name = "set_pan"
    public let description = "Set pan position, -64 (hard left) … 0 (center) … +63 (hard right). Verified by V-Pot ring echo."
    public let inputSchema = trackArgSchema(["position": .object(["type": .string("integer")])], required: ["position"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let position = args["position"]?.intValue, (-64...63).contains(position) else {
            throw ToolFailure(error: "'position' must be an integer in -64…63", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.assignPan)   // ensure V-Pots are in pan mode
        // Pan over MCU is delta-only: sweep hard left (-127 ticks ≥ full range), then tick up to target.
        async let ringSeen = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .vpotRing(channel, _) = $0 { return true } else { return false }
        }
        await daemon.session.turnVPot(channel: channel, ticks: -127)
        await daemon.session.turnVPot(channel: channel, ticks: position + 64)
        guard await ringSeen != nil else {
            throw ToolFailure(error: "pan not confirmed", layer: "mcu",
                              expected: "V-Pot ring echo on channel \(channel)", observed: "no echo within 1s")
        }
        let priorPan = track.pan
        await daemon.model.updateTrack(index: track.index) { $0.pan = position + 64 }
        await daemon.journal.record(MixMutation(
            tool: "set_pan", track: track.name,
            undoArguments: priorPan.map { ["track": track.name, "position": String($0 - 64)] },
            descriptionText: "\(track.name) pan \(priorPan.map { String($0 - 64) } ?? "?") → \(position)"))
        return .object(["track": .string(track.name), "pan": .int(position)])
    }
}

public struct SetAutomationModeTool: LogicTool {
    public let name = "set_automation_mode"
    public let description = "Set a track's automation mode: read, write, touch, or latch. Selects the track first; verified by the automation button LED."
    public let inputSchema = trackArgSchema(["mode": .object([
        "type": .string("string"), "enum": .array([.string("read"), .string("write"), .string("touch"), .string("latch")]),
    ])], required: ["mode"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let mode = try requireString(args, "mode", tool: name)
        let button: MCUButton = switch mode {
        case "read": .automationRead
        case "write": .automationWrite
        case "touch": .automationTouch
        case "latch": .automationLatch
        default: throw ToolFailure(error: "mode must be read|write|touch|latch", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.select(channel: channel))   // automation buttons act on selection
        async let led = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .led(button, .on) = $0 { return true } else { return false }
        }
        await daemon.session.press(button)
        guard await led != nil else {
            throw ToolFailure(error: "automation mode not confirmed", layer: "mcu",
                              expected: "\(mode) LED on", observed: "no LED echo within 1s")
        }
        return .object(["track": .string(track.name), "automationMode": .string(mode)])
    }
}
