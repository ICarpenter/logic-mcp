import Foundation
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
    public let description = "Set a track's volume fader. Pass exactly one of: db (absolute, -∞ as -100 … +6.0) or delta (relative dB). Converges on the target by nudging the AX slider and re-reading Logic's own fader-level title; returns the dB Logic actually shows ('source':'ax')."
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
        let strip = try await daemon.ax.find(trackName)
        guard let vol = await daemon.ax.control(strip, description: "volume fader") else {
            throw ToolFailure(error: "no volume fader", layer: "ax",
                              expected: "a volume slider on '\(trackName)'", observed: "none")
        }
        func currentDB() async -> Double? {
            guard let title = await daemon.ax.titleOfLevel(strip),
                  let parsed = AXStrip.parseDB(title) else { return nil }
            return parsed.db
        }
        let startDB = await currentDB()
        let targetDB: Double
        if let db { targetDB = db }
        else {
            guard let s = startDB else {
                throw ToolFailure(error: "current volume unknown; cannot apply delta", layer: "ax",
                                  expected: "a readable fader level for '\(trackName)'", observed: "none")
            }
            targetDB = s + delta!
        }
        let achieved = try await axConvergeVolume(daemon, strip: strip, slider: vol, targetDB: targetDB)
        let name = await daemon.ax.read(strip).name
        if let idx = await daemon.model.indexOf(name) {
            await daemon.model.updateTrack(index: idx) {
                $0.volumeDB = achieved; $0.volumeIsSilent = (achieved == nil)
            }
        }
        await daemon.journal.record(MixMutation(
            tool: "set_volume", track: name,
            undoArguments: startDB.map { ["track": name, "db": String($0)] },
            descriptionText: "\(name) volume \(startDB.map { String($0) } ?? "-∞") → \(achieved.map { String($0) } ?? "-∞") dB"))
        return .object([
            "track": .string(name),
            "volumeDB": achieved.map { Value.double($0) } ?? .null,
            "source": .string("ax"),
        ])
    }
}

/// Converge the fader on `targetDB` by nudging (AXSetValue moves ±1 toward the passed value —
/// ax-findings.md). Oracle: the dB fader-level title. Handles a SILENT (−∞) start by climbing
/// out toward the slider max. Uses the slider's raw value for stuck-detection so the silent
/// region (where the title has no number) doesn't read as "stuck". Returns the dB Logic renders
/// (nil ⇒ silent). `SILENCE_DB`: a target at or below this is treated as "wants silence".
func axConvergeVolume(_ daemon: Daemon, strip: AXHandle, slider: AXHandle, targetDB: Double) async throws -> Double? {
    let SILENCE_DB = -95.0
    func level() async -> (db: Double?, silent: Bool)? {
        guard let t = await daemon.ax.titleOfLevel(strip) else { return nil }
        return AXStrip.parseDB(t)
    }
    let (loOpt, hiOpt) = await daemon.ax.minMax(of: slider)
    let lo = loOpt ?? 0, hi = hiOpt ?? 233
    var lastRaw = await daemon.ax.value(of: slider)
    for _ in 0..<400 {
        guard let lvl = await level() else { break }               // no title ⇒ truly unreadable
        if lvl.silent && targetDB <= SILENCE_DB { return nil }      // wants silence, already silent
        if let cur = lvl.db, abs(cur - targetDB) <= 0.1 { return cur }
        let dirDB = lvl.db ?? -Double.infinity                      // silent ⇒ climb toward hi
        try await daemon.ax.setValue(dirDB < targetDB ? hi : lo, of: slider)
        // Don't trust a single immediate post-nudge read as "stuck": AXSetValue updates the
        // slider's raw value ASYNCHRONOUSLY on real Logic, so an immediate re-read can return
        // the stale pre-nudge value and falsely look like a boundary (real-Logic smoke bug —
        // see AXBridge.settledValue). Only bail once the settle-poll confirms it really didn't move.
        let nowRaw = await daemon.ax.settledValue(of: slider, unlessChangedFrom: lastRaw)
        if nowRaw == lastRaw { return (await level())?.db }         // still unchanged after settling ⇒ at a boundary
        lastRaw = nowRaw
    }
    return (await level())?.db
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

/// Mute/solo via AX: read the switch's value, press only if it differs, verify by re-read.
/// Idempotent by construction. No focus, no MCU.
func setToggleAX(_ daemon: Daemon, trackName: String, on: Bool, isMute: Bool) async throws -> Value {
    let label = isMute ? "mute" : "solo"
    let strip = try await daemon.ax.find(trackName)
    let priorControls = await daemon.ax.read(strip)
    let prior = isMute ? priorControls.mute : priorControls.solo
    guard let button = await daemon.ax.control(strip, description: label) else {
        throw ToolFailure(error: "no \(label) control", layer: "ax",
                          expected: "a \(label) button on '\(trackName)'", observed: "none")
    }
    let current = await daemon.ax.stringValue(.value, of: button) == "on"
    if current != on {
        try await daemon.ax.press(button)
        // AXPress updates the switch's value ASYNCHRONOUSLY on real Logic — an immediate
        // re-read returns the stale pre-press value. Poll until the value catches up or a
        // 1s deadline passes, instead of trusting a single read.
        var after = current
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            after = await daemon.ax.stringValue(.value, of: button) == "on"
            if after == on { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard after == on else {
            throw ToolFailure(error: "\(label) not confirmed", layer: "ax",
                              expected: "\(label) \(on)", observed: "\(after)")
        }
    }
    let name = priorControls.name
    await daemon.journal.record(MixMutation(
        tool: isMute ? "set_mute" : "set_solo", track: name,
        undoArguments: ["track": name, "on": prior ? "true" : "false"],
        descriptionText: "\(name) \(label) \(prior) → \(on)"))
    if let idx = await daemon.model.indexOf(name) {
        await daemon.model.updateTrack(index: idx) { if isMute { $0.mute = on } else { $0.solo = on } }
    }
    return .object(["track": .string(name), label: .bool(on)])
}

public struct SetMuteTool: LogicTool {
    public let name = "set_mute"
    public let description = "Mute or unmute a track. Idempotent; verified by re-reading the AX mute switch."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggleAX(daemon, trackName: trackName, on: on, isMute: true)
    }
}

public struct SetSoloTool: LogicTool {
    public let name = "set_solo"
    public let description = "Solo or unsolo a track. Idempotent; verified by re-reading the AX solo switch."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggleAX(daemon, trackName: trackName, on: on, isMute: false)
    }
}

public struct SetPanTool: LogicTool {
    public let name = "set_pan"
    public let description = "Set pan position, -64 (hard left) … 0 (center) … +63 (hard right). Converges on the target by nudging the AX pan slider and re-reading it; returns the value actually achieved ('source':'ax')."
    public let inputSchema = trackArgSchema(["position": .object(["type": .string("integer")])], required: ["position"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let position = args["position"]?.coercedInt, (-64...63).contains(position) else {
            throw ToolFailure(error: "'position' must be an integer in -64…63", layer: "daemon")
        }
        let strip = try await daemon.ax.find(trackName)
        guard let pan = await daemon.ax.control(strip, description: "pan") else {
            throw ToolFailure(error: "no pan control", layer: "ax",
                              expected: "a pan slider on '\(trackName)'", observed: "none")
        }
        guard await daemon.ax.isSettable(pan) else {
            throw ToolFailure(error: "pan not settable via AX", layer: "ax",
                              expected: "a settable pan slider", observed: "read-only")
        }
        // Undo baseline comes from the AX-observed value BEFORE the write, mirroring
        // set_volume/setToggleAX (both capture prior-from-AX) — not the shadow model: if
        // set_pan runs before any AX sync the model has no entry (undo baseline silently nil),
        // and if the model is stale vs AX, undo would restore a stale value instead of what
        // Logic actually had.
        let priorRaw = await daemon.ax.value(of: pan).map { Int($0.rounded()) }
        // AX pan range is −64…63 (matches the tool's `position`); AXSetValue nudges ±1 per call
        // (ax-findings.md), so converge with nudgeToRaw. 128 steps covers the full range.
        let observedRaw = try await daemon.ax.nudgeToRaw(pan, target: Double(position), maxSteps: 128)
        let observed = Int(observedRaw.rounded())
        let name = await daemon.ax.read(strip).name
        if let idx = await daemon.model.indexOf(name) {
            await daemon.model.updateTrack(index: idx) { $0.pan = observed + 64 }
        }
        await daemon.journal.record(MixMutation(
            tool: "set_pan", track: name,
            undoArguments: priorRaw.map { ["track": name, "position": String($0)] },
            descriptionText: "\(name) pan \(priorRaw.map { String($0) } ?? "?") → \(observed)"))
        return .object(["track": .string(name), "pan": .int(observed), "source": .string("ax")])
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
