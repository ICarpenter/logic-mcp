import Foundation
import MCP

func trackValue(_ t: TrackState) -> Value {
    .object([
        "index": .int(t.index),
        "name": .string(t.name),
        "volumeDB": t.volumeDB.map { Value.double($0) } ?? .null,
        "volumeIsSilent": .bool(t.volumeIsSilent),
        "pan": t.pan.map { Value.int($0 - 64) } ?? .null,
        "mute": .bool(t.mute),
        "solo": .bool(t.solo),
    ])
}

func overviewValue(_ snapshot: (tracks: [TrackState], transport: TransportState, staleAt: Date?)) -> Value {
    .object([
        "tracks": .array(snapshot.tracks.map(trackValue)),
        "transport": .object([
            "playing": .bool(snapshot.transport.playing),
            "recording": .bool(snapshot.transport.recording),
            "cycling": .bool(snapshot.transport.cycling),
        ]),
        "stale": .bool(snapshot.staleAt != nil),
    ])
}

/// Shared: pull a required string argument or throw the standard failure.
/// (If this SDK version lacks a `stringValue`/`intValue`/`boolValue`/`doubleValue`
/// convenience on `Value`, pattern-match the enum case here once — every tool funnels
/// argument access through these helpers.)
func requireString(_ args: [String: Value], _ key: String, tool: String) throws -> String {
    guard let value = args[key]?.stringValue else {
        throw ToolFailure(error: "missing required argument '\(key)' for \(tool)", layer: "daemon")
    }
    return value
}

// MARK: - JSON-faithful numeric coercion
//
// JSON has exactly ONE number type, but the MCP SDK decodes it into two case-strict
// `Value` cases: `-12` becomes `.int(-12)` and `-12.5` becomes `.double(-12.5)`. The
// SDK's `intValue`/`doubleValue` accessors match ONLY their own case
// (`.int(-12).doubleValue == nil`, `.double(2.0).intValue == nil`), so a caller who
// writes the perfectly valid JSON `db: -12` gets rejected by `doubleValue`. Do NOT
// assume the SDK reconciles the two cases — it does not. Every numeric tool argument
// funnels through these coercing accessors so either spelling is accepted the way JSON
// semantics imply.
extension Value {
    /// A `Double` from either a JSON float (`.double`) or a JSON integer (`.int`).
    var coercedDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    /// An `Int` from a JSON integer (`.int`), or from a JSON float (`.double`) ONLY when
    /// it is integral and fits in `Int`. A non-integral value like `2.5` is rejected,
    /// never silently truncated — an integer field should refuse a fractional number.
    var coercedInt: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.rounded() == d else { return nil }   // integral only
            return Int(exactly: d)                        // also enforces Int range
        default: return nil
        }
    }
}

public struct GetProjectOverviewTool: LogicTool {
    public let name = "get_project_overview"
    public let description = "Snapshot of the shadow project model: all tracks with mix state, plus transport. Cheap; does not touch Logic. If 'stale' is true, call refresh_state first."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        if await daemon.model.snapshot.staleAt != nil {
            _ = try? await daemon.navigator.enumerateTracks()   // best effort; still returns whatever we have
        }
        return await overviewValue(daemon.model.snapshot)
    }
}

public struct GetTrackTool: LogicTool {
    public let name = "get_track"
    public let description = "Mix state for one track by name (case-insensitive; unique prefix accepted)."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        return trackValue(try await daemon.navigator.resolve(name))
    }
}

public struct RefreshStateTool: LogicTool {
    public let name = "refresh_state"
    public let description = "Re-scan Logic over the MCU wire and rebuild the shadow model. scope: 'tracks' (default) re-enumerates the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["scope": .object(["type": .string("string")])]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        _ = try await daemon.navigator.enumerateTracks()
        return await overviewValue(daemon.model.snapshot)
    }
}
