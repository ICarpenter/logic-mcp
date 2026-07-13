import Foundation
import MCP

public struct CreateTrackTool: LogicTool {
    public let name = "create_track"
    public let description = "Create a new track. kind: 'audio' | 'software-instrument' | 'midi'. Logic assigns the default name (e.g. 'Audio 1'); renaming is not available via AX in this release. Verified by re-reading the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "kind": .object(["type": .string("string"), "enum": .array([.string("audio"), .string("software-instrument"), .string("midi")])]),
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
        return .object(["created": .bool(true), "track": .string(created), "kind": .string(kind)])
    }
}

public struct RenameTrackTool: LogicTool {
    public let name = "rename_track"
    public let description = "Rename a track. NOTE: renaming is not available via the Accessibility path in this release; this tool returns a structured error directing you to Logic directly. (Reading/selecting tracks still works via refresh_state/select_track.)"
    public let inputSchema = trackArgSchema(["to": .object(["type": .string("string")])], required: ["to"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        _ = try requireString(args, "to", tool: name)
        // Resolve via AX first so a bad/ambiguous track name still gives the precise
        // AXBridge.find() error, not a blanket "not available" that would mask it.
        let strip = try await daemon.ax.find(trackName)
        let resolved = await daemon.ax.read(strip).name
        throw ToolFailure(
            error: "renaming a track is not available via AX in this release",
            layer: "ax",
            expected: "rename '\(resolved)' in Logic directly",
            observed: "Logic's track-name fields are not AX-committable — AXSetValue changes the field cosmetically but never commits the edit (see Fixtures/ax/rename.txt)")
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

public struct DeleteTrackTool: LogicTool {
    public let name = "delete_track"
    public let description = "Delete a track. Reversible via Logic-native undo (call undo_structural to restore). Verified by re-reading the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(name)             // throws layer:"ax" if unknown
        let resolved = await daemon.ax.read(strip).name
        try await daemon.menu.pressElement(strip)              // select the target
        try await daemon.menu.pressMenuPath(["Track", "Delete Track"])
        // Verify: the strip disappeared. Logic's AX tree updates ASYNCHRONOUSLY after a menu
        // press (see create_track's settleTracks comment) — settle-poll instead of trusting a
        // single immediate re-read.
        let after = try await settleTracks(daemon) { names in !names.contains(resolved) }
        guard !after.contains(resolved) else {
            throw ToolFailure(error: "delete not confirmed", layer: "ax",
                              expected: "'\(resolved)' gone", observed: "still present")
        }
        return .object(["deleted": .string(resolved), "reversible": .string("call undo_structural")])
    }
}

public struct UndoStructuralTool: LogicTool {
    public let name = "undo_structural"
    public let description = "Undo the last structural edit via Logic's Edit ▸ Undo (e.g. reverse a delete_track/create_track)."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let before = try await currentTrackNames(daemon)
        try await daemon.menu.pressMenuPath(["Edit", "Undo"])
        // Same async-AX-update hazard as create_track/delete_track — settle-poll until the
        // mixer's track list actually reflects the undo instead of trusting an immediate re-read.
        _ = try await settleTracks(daemon) { names in names != before }
        return .object(["undone": .bool(true)])
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
