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
    public let description = "Rename a track. NOTE: renaming is not available via the Accessibility path in this release; this tool returns a structured error directing you to Logic directly. (Reading tracks still works via refresh_state/get_track.)"
    public let inputSchema = trackArgSchema(["to": .object(["type": .string("string")])], required: ["to"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        _ = try requireString(args, "to", tool: name)
        // Resolve via AX first so a bad/ambiguous track name still gives the precise
        // AXBridge.find() error, not a blanket "not available" that would mask it.
        let strip = try await daemon.mixerStrip(named: trackName)
        let resolved = await daemon.ax.read(strip).name
        throw ToolFailure(
            error: "renaming a track is not available via AX in this release",
            layer: "ax",
            expected: "rename '\(resolved)' in Logic directly",
            observed: "Logic's track-name fields are not AX-committable — AXSetValue changes the field cosmetically but never commits the edit (see Fixtures/ax/rename.txt)")
    }
}

public struct DeleteTrackTool: LogicTool {
    public let name = "delete_track"
    public let description = "Delete a track by name. Selects it first (via the arrange header's Has Focus) and CONFIRMS exactly that track is focused before invoking Track ▸ Delete Track — so it never deletes the wrong track. Refuses if selection can't be confirmed. Reversible via undo_structural."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        // Guard: SELECT the named track and confirm EXACTLY it is focused. Never proceed otherwise —
        // Track ▸ Delete Track acts on the SELECTED track, so an unconfirmed selection risks the
        // wrong-track destructive bug that disabled this tool (see ax-findings.md selection notes).
        let confirmed = try await selectTrackConfirmed(daemon, name)   // throws layer:"ax" if name unknown
        guard confirmed else {
            throw ToolFailure(error: "refusing to delete: could not confirm '\(name)' is the selected track", layer: "ax",
                              expected: "exactly '\(name)' focused after select", observed: "selection unconfirmed — nothing deleted")
        }
        let before = Set(try await currentTrackNames(daemon))
        try await daemon.menu.pressMenuPath(["Track", "Delete Track"])
        let after = try await settleTracks(daemon) { names in !names.contains(name) || names.count < before.count }
        guard !after.contains(name) else {
            throw ToolFailure(error: "delete not confirmed", layer: "ax",
                              expected: "'\(name)' gone from the mixer", observed: "still present")
        }
        return .object(["deleted": .bool(true), "track": .string(name)])
    }
}

public struct SetOutputTool: LogicTool {
    public let name = "set_output"
    public let description = "Set a track's output destination (a bus or output). The routing popup is NESTED — destinations live one submenu deep under 'Output ▸'/'Bus ▸' — so callers just pass the destination name (e.g. 'Bus 3', 'Stereo Output', 'No Output') and the tool finds it. Verified by re-reading the strip's output slot."
    public let inputSchema = trackArgSchema(["dest": .object(["type": .string("string")])], required: ["dest"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let track = try requireString(args, "track", tool: name)
        let dest = try requireString(args, "dest", tool: name)
        let strip = try await daemon.mixerStrip(named: track)
        // The routing slot is found STRUCTURALLY (the plain AXButton immediately after the "group"
        // popup — see AXBridge.outputButton). nil means the strip genuinely HAS no output slot:
        // Stereo Out and Master don't have one (Fixtures/ax/strip_special.txt). Refuse. The old
        // by-exclusion search handed us an unrelated mixer-panel button here ("bounce", "dim") and
        // we would have PRESSED it.
        guard let outBtn = await daemon.ax.outputButtonHandle(strip) else {
            throw ToolFailure(error: "strip '\(track)' has no output slot", layer: "ax",
                              expected: "an output-routing button on the strip",
                              observed: "this strip has no routing slot in Logic's mixer (Stereo Out / Master don't have one) — nothing was pressed")
        }
        try await daemon.menu.selectRoutingDestination(from: outBtn, dest: dest)   // search-driven popup (like insert_plugin)
        // Confirm by RE-RESOLVING the strip by name each poll (settleOutputByName): selecting a
        // destination re-renders the strip and — routing to a fresh bus — inserts an Aux that shifts
        // indices, so the `strip` handle captured above goes STALE (real Logic read it "unreadable"
        // for the whole timeout → a false "not confirmed" for a routing that landed). A fresh mixer
        // walk sees the new destination. (settleOutput polls the STRIP'S OUTPUT, not the track list.)
        let now = await settleOutputByName(daemon, track: track) { $0?.caseInsensitiveCompare(dest) == .orderedSame }
        guard now?.caseInsensitiveCompare(dest) == .orderedSame else {
            throw ToolFailure(error: "output change not confirmed", layer: "ax",
                              expected: dest, observed: now ?? "unreadable")
        }
        return .object(["track": .string(track), "output": .string(now ?? dest)])
    }
}

public struct UndoStructuralTool: LogicTool {
    public let name = "undo_structural"
    public let description = "Undo the last structural edit via Logic's Edit ▸ Undo (e.g. reverse a create_track or an insert_plugin). Returns the FULL title Logic gave the undo item (e.g. 'Undo Create Track') — that is what was actually reverted."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let before = try await currentTrackNames(daemon)
        // BUG 3: Logic RETITLES the item per operation ("Undo Create Track", "Undo Delete
        // Tracks"), so an equality match on "Undo" works exactly once and then fails forever.
        // Match by PREFIX and report the full title back — it names what Logic reverted, and it
        // is the only independent oracle we get (the press's return code means nothing).
        let title = try await daemon.menu.pressMenuItemWithPrefix(menu: "Edit", prefix: "Undo")
        // Same async-AX-update hazard as create_track — settle-poll until the mixer's track list
        // reflects the undo instead of trusting an immediate re-read. NOTE: an undo that changes
        // something OTHER than the track list (e.g. undoing an insert_plugin or a set_output)
        // leaves the list equal, so this poll just runs out its deadline; the reported title, not
        // this poll, is the tool's evidence.
        _ = try await settleTracks(daemon) { names in names != before }
        return .object(["undone": .string(title)])
    }
}

// Shared helpers used across structure tools.
func currentTrackNames(_ daemon: Daemon) async throws -> [String] {
    try await daemon.syncMixer()
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

/// Poll the STRIP'S OUTPUT SLOT (re-reading via AX) until `condition` holds on the output string,
/// or the deadline passes — RE-RESOLVING the strip by NAME each poll (not a handle captured before
/// the edit). `settleTracks` above polls the mixer's track-name list — the wrong oracle for
/// `set_output`, whose effect lands on one strip's output button, not the strip list.
///
/// Why re-resolve by name: selecting a routing destination re-renders the strip — and routing to a
/// fresh bus INSERTS an Aux, shifting strip indices — INVALIDATING the pre-press AXLayoutItem handle
/// (real Logic, 2026-07-15). A handle-based poll read the stale handle's output as "unreadable"/old
/// for the whole timeout, so `set_output` reported "output change not confirmed" for a routing that
/// ACTUALLY LANDED — a false negative (same class as insert_plugin's). A fresh mixer walk each poll
/// sees the new destination; a re-find that throws during the transient counts as "not settled yet".
@discardableResult
func settleOutputByName(_ daemon: Daemon, track: String, timeout: Duration = .seconds(3),
                        until condition: (String?) -> Bool) async -> String? {
    func read() async -> String? {
        guard let s = try? await daemon.ax.find(track) else { return nil }
        return await daemon.ax.read(s).output
    }
    var output = await read()
    if condition(output) { return output }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        output = await read()
        if condition(output) { return output }
    }
    return output
}

/// Poll the STRIP'S PLUGIN GROUPS (re-reading via AX) until `condition` holds on the group-name
/// list, or the deadline passes. Neither `settleTracks` (the mixer's track-name list) nor
/// `settleOutput` (one strip's output slot) is the right oracle for `insert_plugin`, whose effect
/// lands on the strip's plugin-insert slots — same async-AX-update hazard as both: a popup-leaf
/// press's effect on the strip's children can lag the press ("blind-press-then-read" is this
/// codebase's top bug class). Polls every 50ms for up to `timeout`. Returns the final group-name
/// list.
@discardableResult
func settlePlugins(_ daemon: Daemon, strip: AXHandle, timeout: Duration = .seconds(3),
                   until condition: ([String]) -> Bool) async -> [String] {
    var names = await daemon.ax.pluginGroups(strip).map(\.name)
    if condition(names) { return names }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        names = await daemon.ax.pluginGroups(strip).map(\.name)
        if condition(names) { return names }
    }
    return names
}

/// Like `settlePlugins`, but RE-RESOLVES the strip by NAME on every poll instead of reusing a
/// handle captured before the edit. Inserting a plugin makes Logic re-render the strip and
/// INVALIDATE the pre-insert AXLayoutItem handle (real Logic, 2026-07-15, mcp_test.logicx): the
/// reused handle then reads ZERO plugin groups for the full timeout, so `insert_plugin` reported
/// "plugin insert not confirmed" for an insert that ACTUALLY LANDED — a false negative that invites
/// a duplicate-insert retry. A fresh mixer walk each poll (what `axdump` does) sees the new group.
/// A re-find that throws during the transient (strip momentarily gone) counts as "not settled yet".
@discardableResult
func settlePluginsByName(_ daemon: Daemon, track: String, timeout: Duration = .seconds(3),
                         until condition: ([String]) -> Bool) async -> [String] {
    func read() async -> [String] {
        guard let s = try? await daemon.ax.find(track) else { return [] }
        return await daemon.ax.pluginGroups(s).map(\.name)
    }
    var names = await read()
    if condition(names) { return names }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        names = await read()
        if condition(names) { return names }
    }
    return names
}
