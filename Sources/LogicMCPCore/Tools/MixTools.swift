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
    public let description = "Set a track's volume fader. Pass exactly one of: db (absolute, -∞ as -100 … +6.0) or delta (relative dB). Returns the dB Logic prints on its LCD when the fader banner is readable ('source':'logic'); otherwise a value interpolated from the calibrated fader curve ('source':'curve')."
    public let inputSchema = trackArgSchema([
        "db": .object(["type": .string("number")]),
        "delta": .object(["type": .string("number")]),
    ], required: [])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        // Distinguish the three failure modes so the message is accurate. The old
        // guard collapsed "neither supplied", "both supplied", and "supplied but not a
        // number" into one misleading "needs exactly one" — e.g. `db: -12` (a valid
        // integer) was rejected by `doubleValue` and reported as if nothing was passed.
        let hasDB = args["db"] != nil
        let hasDelta = args["delta"] != nil
        guard hasDB || hasDelta else {
            throw ToolFailure(error: "set_volume needs one of 'db' or 'delta'; neither was supplied", layer: "daemon")
        }
        guard !(hasDB && hasDelta) else {
            throw ToolFailure(error: "set_volume takes only one of 'db' or 'delta'; both were supplied", layer: "daemon")
        }
        var db: Double?
        var delta: Double?
        if hasDB {
            guard let value = args["db"]?.coercedDouble else {
                throw ToolFailure(error: "'db' must be a number", layer: "daemon")
            }
            db = value
        } else {
            guard let value = args["delta"]?.coercedDouble else {
                throw ToolFailure(error: "'delta' must be a number", layer: "daemon")
            }
            delta = value
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

        // The curve only SEEDS the move — the MCU wire carries a 14-bit position, never dB.
        let echoedRaw = try await daemon.session.moveFader(
            channel: channel, toRaw: FaderCurve.raw(fromDB: targetDB), timeout: .seconds(1))
        // Logic prints the exact dB on the LCD only while the fader banner is up (~2s). Let it
        // settle, then read Logic's own number; fall back to the interpolated curve only when
        // the banner cannot be read. `source` tells the caller which one they got.
        await daemon.session.settle(.milliseconds(150))
        let banner = SurfaceDisplay.valueText(await daemon.session.surface, line: 1, channel: channel)
        let usedDB: Double?
        let source: String
        switch SurfaceDisplay.parseDB(banner) {
        case .some(let value):   // a real dB, or a recognized "-oo" (value == nil means silent)
            usedDB = value
            source = "logic"
        case .none:              // no readable banner — interpolate from the calibrated curve
            usedDB = FaderCurve.dB(fromRaw: echoedRaw)
            source = "curve"
        }
        await daemon.model.updateTrack(index: track.index) {
            $0.volumeRaw = echoedRaw
            $0.volumeDB = usedDB
            $0.volumeIsSilent = usedDB == nil
        }
        let priorDB = track.volumeDB
        await daemon.journal.record(MixMutation(
            tool: "set_volume", track: track.name,
            undoArguments: priorDB.map { ["track": track.name, "db": String($0)] },
            descriptionText: "\(track.name) volume \(priorDB.map { String($0) } ?? "-∞") → \(usedDB.map { String($0) } ?? "-∞") dB"))
        return .object([
            "track": .string(track.name),
            "volumeDB": usedDB.map { Value.double($0) } ?? .null,
            "volumeRaw": .int(echoedRaw),
            "source": .string(source),
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
    let target = button(channel)
    let current = await daemon.session.surface.leds[target] == .on
    if current != on {
        // Open the event subscription BEFORE pressing. `events()` is live-only, so an
        // `async let` that subscribes after the press can miss an echo Logic delivers before
        // the subscription registers (the moveFader shape avoids exactly this).
        let stream = await daemon.session.events()
        await daemon.session.press(target)
        let led = await MCUSession.first(of: stream, timeout: .seconds(1)) {
            if case .led(let b, let s) = $0 { return b == target && s == (on ? .on : .off) } else { return false }
        }
        guard led != nil else {
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
    public let description = "Set pan position, -64 (hard left) … 0 (center) … +63 (hard right). Returns the signed pan Logic prints on its LCD ('source':'logic'); Logic may snap, so the result can differ from the request. Falls back to the requested value ('source':'requested') if the LCD cell is unreadable."
    public let inputSchema = trackArgSchema(["position": .object(["type": .string("integer")])], required: ["position"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let position = args["position"]?.coercedInt, (-64...63).contains(position) else {
            throw ToolFailure(error: "'position' must be an integer in -64…63", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        // Drive the surface to a KNOWN state (per-channel pan, values) instead of pressing
        // `.assignPan` blind. `.assignPan` is a TOGGLE: an unconditional press flips Logic
        // INTO the dead single-parameter page, where only V-Pot 0 is live and this channel's
        // sweep would move nothing. normalizeSurface observes each axis and only presses when
        // the observed state is wrong, leaving per-channel pan with values on the bottom row.
        try await daemon.navigator.normalizeSurface()
        // Pan over MCU is delta-only: sweep hard left (-127 ticks ≥ full range), then tick up.
        await daemon.session.turnVPot(channel: channel, ticks: -127)
        await daemon.session.turnVPot(channel: channel, ticks: position + 64)
        // Let the V-Pot traffic go quiet, so the sweep has landed before we read it back and
        // before a following tool call can interleave with a still-moving pan.
        await daemon.session.settle(.milliseconds(150))

        // Verify by READING Logic's own number, never by waiting for a V-Pot ring echo.
        // Measured on real Logic: the two turn bursts arrive faster than Logic refreshes the
        // ring, so it coalesces them — sweeping -47 → -64 → -47 leaves the ring exactly where
        // it started and Logic emits NO echo at all. A ring-echo guard therefore reports
        // failure in precisely the case where the pan is ALREADY at the requested value.
        // The bottom LCD row always carries the landed pan as a signed integer, one cell per
        // channel, and `normalizeSurface()` above guarantees that row is in VALUES mode.
        let panCell = await daemon.session.surface.lcdCell(line: 1, channel: channel)
        guard let observed = SurfaceDisplay.parsePan(panCell) else {
            throw ToolFailure(
                error: "pan not confirmed", layer: "mcu",
                expected: "a signed pan value on the bottom LCD row for channel \(channel)",
                observed: "unreadable cell '\(panCell.trimmingCharacters(in: .whitespaces))'"
                    + " — does '\(track.name)' have a pan control?")
        }
        let source = "logic"
        let priorPan = track.pan
        await daemon.model.updateTrack(index: track.index) { $0.pan = observed + 64 }
        await daemon.journal.record(MixMutation(
            tool: "set_pan", track: track.name,
            undoArguments: priorPan.map { ["track": track.name, "position": String($0 - 64)] },
            descriptionText: "\(track.name) pan \(priorPan.map { String($0 - 64) } ?? "?") → \(observed)"))
        // The surface is left in the normalized state (per-channel pan, values) with track
        // names back on the top row — nothing to clear, and the next enumeration reads names.
        return .object([
            "track": .string(track.name),
            "pan": .int(observed),
            "source": .string(source),
        ])
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
        // Open the subscription BEFORE pressing the automation button — `events()` is live-only.
        let stream = await daemon.session.events()
        await daemon.session.press(button)
        let led = await MCUSession.first(of: stream, timeout: .seconds(1)) {
            if case .led(button, .on) = $0 { return true } else { return false }
        }
        guard led != nil else {
            throw ToolFailure(error: "automation mode not confirmed", layer: "mcu",
                              expected: "\(mode) LED on", observed: "no LED echo within 1s")
        }
        return .object(["track": .string(track.name), "automationMode": .string(mode)])
    }
}
