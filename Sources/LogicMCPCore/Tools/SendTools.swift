import MCP

public struct SetSendTool: LogicTool {
    public let name = "set_send"
    public let description = "Set a send level (0-127) from a track to a bus. Uses the MCU send page; the returned level is read back off Logic's LCD."
    public let inputSchema = trackArgSchema([
        "bus": .object(["type": .string("string")]),
        "level": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(127)]),
    ], required: ["bus", "level"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let bus = try requireString(args, "bus", tool: name)
        guard let level = args["level"]?.intValue, (0...127).contains(level) else {
            throw ToolFailure(error: "'level' must be an integer in 0…127", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.select(channel: channel))
        await daemon.session.press(.assignSend)
        await daemon.session.settle(.milliseconds(150))

        // Restore the pan view all other tools assume — awaited on every exit path
        // (a fire-and-forget defer would race the next tool call).
        func restoreMode() async { await daemon.session.press(.assignPan) }

        let surface = await daemon.session.surface
        let wanted = bus.lowercased()
        guard let cell = (0..<8).first(where: {
            surface.lcdCell(line: 0, channel: $0).trimmingCharacters(in: .whitespaces)
                .lowercased().hasPrefix(String(wanted.prefix(7)))
        }) else {
            await restoreMode()
            throw ToolFailure(error: "no send to '\(bus)' on '\(track.name)'", layer: "mcu",
                              expected: "a send cell matching '\(bus)'",
                              observed: surface.lcdTop)
        }

        let priorDisplay = surface.lcdCell(line: 1, channel: cell).trimmingCharacters(in: .whitespaces)

        await daemon.session.turnVPot(channel: cell, ticks: -127)         // to zero
        await daemon.session.turnVPot(channel: cell, ticks: level)        // up to target
        await daemon.session.settle(.milliseconds(150))

        let after = await daemon.session.surface
        let display = after.lcdCell(line: 1, channel: cell).trimmingCharacters(in: .whitespaces)
        await restoreMode()
        guard let echoed = Int(display) else {
            throw ToolFailure(error: "send level not confirmed", layer: "mcu",
                              expected: "numeric level in LCD cell \(cell)", observed: display)
        }
        await daemon.journal.record(MixMutation(
            tool: "set_send", track: track.name,
            undoArguments: Int(priorDisplay).map { ["track": track.name, "bus": bus, "level": String($0)] },
            descriptionText: "\(track.name) send \(bus) \(priorDisplay) → \(echoed)"))
        return .object(["track": .string(track.name), "bus": .string(bus), "level": .int(echoed)])
    }
}
