import MCP

/// Insert an audio plugin via the strip's three-level insert popup (Fixtures/ax/popup_plugin.txt):
/// top level holds RECENT plugins AND categories; a category's submenu holds plugin names; a
/// plugin's submenu holds the CHANNEL-CONFIG leaves (Stereo/Dual Mono) — the pressable leaf, not
/// the plugin name. `AXMenuDriver.selectPluginFromPopup` does the search + press; this tool
/// resolves the strip/slot, drives that, then settle-polls `pluginGroups` to confirm — the same
/// async-AX-update hazard as create_track/delete_track/set_output (a popup-leaf press's effect on
/// the strip's children can lag the press).
public struct InsertPluginTool: LogicTool {
    public let name = "insert_plugin"
    public let description = "Insert an audio plugin on a track's insert slot by name (e.g. 'Channel EQ', 'Compressor'). Searches Logic's insert popup at the top level (Recent) and one category deep, then picks the 'Stereo' channel configuration (or the first available). Verified by re-reading the strip's plugin slots."
    public let inputSchema = trackArgSchema(["name": .object(["type": .string("string")])], required: ["name"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let track = try requireString(args, "track", tool: name)
        let plugin = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(track)
        guard let slot = await daemon.ax.control(strip, description: "audio plug-in") else {
            throw ToolFailure(error: "no insert slot on '\(track)'", layer: "ax",
                              expected: "the audio plug-in slot", observed: "none")
        }
        try await daemon.menu.selectPluginFromPopup(from: slot, plugin: plugin)
        // Same async-AX-update hazard as create_track/delete_track/set_output's settle helpers:
        // the popup-leaf press's effect on the strip's plugin groups can lag the press —
        // settle-poll instead of trusting a single immediate re-read.
        let groups = await settlePlugins(daemon, strip: strip) { names in
            names.contains { $0.caseInsensitiveCompare(plugin) == .orderedSame }
        }
        guard groups.contains(where: { $0.caseInsensitiveCompare(plugin) == .orderedSame }) else {
            throw ToolFailure(error: "plugin insert not confirmed", layer: "ax",
                              expected: "'\(plugin)' in the strip's plugin slots",
                              observed: "slots: \(groups.joined(separator: ", "))")
        }
        return .object(["track": .string(track), "plugin": .string(plugin)])
    }
}
