import Foundation
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
        // Verify: a new strip appeared. Logic's AX tree updates ASYNCHRONOUSLY after a menu
        // press (real-Logic probe: ~700ms before a new strip was visible), so an immediate
        // re-read routinely misses it — settle-poll instead of trusting a single read.
        let after = try await settleTracks(daemon) { names in names.contains { !before.contains($0) } }
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

/// Poll the mixer (re-reading via AX) until `condition` holds on the track-name list, or the
/// deadline passes. Logic's AX tree updates ASYNCHRONOUSLY after a menu press — an immediate
/// re-read routinely misses the change (real-Logic probe: a new track took ~700ms to appear).
/// Returns the final names. Polls every 50ms for up to `timeout`. Generic over `condition` so
/// it covers both "a new name appeared" (create_track) and "a name disappeared" (delete_track).
@discardableResult
func settleTracks(_ daemon: Daemon, timeout: Duration = .seconds(3),
                  until condition: ([String]) -> Bool) async throws -> [String] {
    var names = try await currentTrackNames(daemon)
    if condition(names) { return names }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        names = try await currentTrackNames(daemon)
        if condition(names) { return names }
    }
    return names
}

/// Rename a track by name via AX. Stubbed here; Task 4 wires the real implementation
/// (locate the strip's name field, set its text, verify via re-read).
func renameTrackAX(_ daemon: Daemon, from: String, to: String) async throws -> String {
    throw ToolFailure(error: "rename not yet implemented", layer: "ax")
}
