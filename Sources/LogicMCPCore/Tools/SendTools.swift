import MCP

public struct SetSendTool: LogicTool {
    public let name = "set_send"
    public let description = "Set a send level from a track to a bus. NOTE: send-level control is not yet available via the Accessibility path in this release; this tool currently returns a structured error directing you to Logic's mixer. (Reading track state still works via refresh_state.)"
    public let inputSchema = trackArgSchema([
        "bus": .object(["type": .string("string")]),
        "level": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(127)]),
    ], required: ["bus", "level"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let bus = try requireString(args, "bus", tool: name)
        guard let level = args["level"]?.coercedInt, (0...127).contains(level) else {
            throw ToolFailure(error: "'level' must be an integer in 0…127", layer: "daemon")
        }
        // Resolve via AX first so a bad/ambiguous track name still gives the precise
        // AXBridge.find() error, not a blanket "not available" that would mask it.
        let strip = try await daemon.ax.find(trackName)
        let name = await daemon.ax.read(strip).name
        // Real Logic's mixer AX tree exposes no settable send-level control (only a
        // send-slot button; see ax-findings.md §Sends). The old MCU send path
        // (.assignSend + blind V-Pot turn + LCD readback) is retired: it could write to
        // whichever track Logic's plugin/assignment view happened to be following, not
        // necessarily the one this call named. Fail safely instead.
        throw ToolFailure(
            error: "send level control is not available via AX in this release",
            layer: "ax",
            expected: "set the send from '\(name)' to '\(bus)' in Logic's mixer directly",
            observed: "Logic's mixer AX tree exposes no settable send-level control (only a send-slot button); the MCU send path was retired because it could target the wrong track")
    }
}
