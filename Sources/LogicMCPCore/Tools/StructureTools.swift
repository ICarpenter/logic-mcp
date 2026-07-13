import MCP

public struct CreateTrackTool: LogicTool {
    public let name = "create_track"
    public let description = "Create a new track. kind: 'audio' | 'software-instrument' | 'midi'. Optional name renames it after creation. Verified by re-reading the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "kind": .object(["type": .string("string"), "enum": .array([.string("audio"), .string("software-instrument"), .string("midi")])]),
            "name": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("kind")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let kind = try requireString(args, "kind", tool: name)
        // Menu titles are captured verbatim in Fixtures/ax/menu_track.txt.
        let item: String
        switch kind {
        case "audio": item = "New Audio Track"
        case "software-instrument": item = "New Software Instrument Track"
        case "midi": item = "New External MIDI Track"
        default: throw ToolFailure(error: "kind must be audio | software-instrument | midi", layer: "daemon")
        }
        let before = Set(try await currentTrackNames(daemon))
        try await daemon.menu.pressMenuPath(["Track", item])
        // Verify: a new strip appeared.
        let after = try await currentTrackNames(daemon)
        guard let created = after.first(where: { !before.contains($0) }) else {
            throw ToolFailure(error: "track creation not confirmed", layer: "ax",
                              expected: "a new strip after '\(item)'", observed: "mixer unchanged")
        }
        var finalName = created
        if let want = args["name"]?.stringValue, want != created {
            _ = try? await renameTrackAX(daemon, from: created, to: want)
            finalName = (try await currentTrackNames(daemon)).contains(want) ? want : created
        }
        return .object(["created": .bool(true), "track": .string(finalName), "kind": .string(kind)])
    }
}

public struct SelectTrackTool: LogicTool {
    public let name = "select_track"
    public let description = "Select a track by name (case-insensitive; unique prefix ok)."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(name)
        // Selecting = pressing the strip's name field / header. Confirm via the resolved name.
        try await daemon.menu.pressElement(strip)
        let resolved = await daemon.ax.read(strip).name
        return .object(["selected": .string(resolved)])
    }
}

// Shared helpers used across structure tools.
func currentTrackNames(_ daemon: Daemon) async throws -> [String] {
    try await daemon.axMixer.syncTracks()
}

/// Rename a track by name via AX. Stubbed here; Task 4 wires the real implementation
/// (locate the strip's name field, set its text, verify via re-read).
func renameTrackAX(_ daemon: Daemon, from: String, to: String) async throws -> String {
    throw ToolFailure(error: "rename not yet implemented", layer: "ax")
}
