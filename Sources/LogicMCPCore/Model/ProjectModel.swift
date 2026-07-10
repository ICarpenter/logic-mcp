import Foundation

public struct TrackState: Codable, Sendable {
    public var index: Int
    public var name: String
    public var volumeRaw: Int?
    public var volumeDB: Double?
    public var volumeIsSilent = false
    public var pan: Int?
    public var mute = false
    public var solo = false
    public var output: String?
}

public struct TransportState: Codable, Sendable {
    public var playing = false
    public var recording = false
    public var cycling = false
    public init() {}
}

public actor ProjectModel {
    private var tracks: [TrackState] = []
    private var transport = TransportState()
    private var staleAt: Date? = Date()   // stale until first enumeration

    public init() {}

    public func replaceTracks(_ names: [String]) {
        tracks = names.enumerated().map { TrackState(index: $0.offset, name: $0.element) }
        staleAt = nil
    }

    public func replaceTracks(_ controls: [AXStripControls]) {
        tracks = controls.enumerated().map { i, c in
            TrackState(index: i, name: c.name, volumeRaw: nil, volumeDB: c.volumeDB,
                       volumeIsSilent: c.volumeSilent,
                       pan: c.pan.map { $0 + 64 }, mute: c.mute, solo: c.solo, output: c.output)
        }
        staleAt = nil
    }

    public func track(named name: String) throws -> TrackState {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = tracks.filter { $0.name.lowercased() == wanted }
        if exact.count == 1 { return exact[0] }
        let known = tracks.map(\.name).joined(separator: ", ")
        if exact.count > 1 {
            throw ToolFailure(error: "ambiguous track name '\(name)'", layer: "model",
                              expected: "a unique track name", observed: known)
        }
        let prefix = tracks.filter { $0.name.lowercased().hasPrefix(wanted) }
        switch prefix.count {
        case 1: return prefix[0]
        case 0: throw ToolFailure(error: "no track named '\(name)'", layer: "model",
                                  expected: "one of the known tracks", observed: known)
        default: throw ToolFailure(error: "ambiguous track name '\(name)'", layer: "model",
                                   expected: "a unique track name",
                                   observed: prefix.map(\.name).joined(separator: ", "))
        }
    }

    public func updateTrack(index: Int, _ mutate: (inout TrackState) -> Void) {
        guard tracks.indices.contains(index) else { return }
        mutate(&tracks[index])
    }

    public func setTransport(_ mutate: (inout TransportState) -> Void) {
        mutate(&transport)
    }

    public var snapshot: (tracks: [TrackState], transport: TransportState, staleAt: Date?) {
        (tracks, transport, staleAt)
    }

    public func markStale() {
        staleAt = Date()
    }
}
