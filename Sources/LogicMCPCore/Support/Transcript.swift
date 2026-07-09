import Foundation

public struct TranscriptEntry: Codable, Equatable, Sendable {
    public var dir: String   // "in" = Logic→daemon, "out" = daemon→Logic
    public var hex: String
    public init(dir: String, hex: String) {
        self.dir = dir
        self.hex = hex
    }
}

public enum Transcript {
    public static func load(_ url: URL) throws -> [TranscriptEntry] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(TranscriptEntry.self, from: Data($0.utf8)) }
    }

    public static func write(_ entries: [TranscriptEntry], to url: URL) throws {
        let lines = try entries.map {
            String(data: try JSONEncoder().encode($0), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func bytes(_ entry: TranscriptEntry) -> [UInt8] {
        entry.hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Replays a transcript's "in" entries; records what the daemon sends.
public actor ScriptedWire: MCUWire {
    private let inEntries: [[UInt8]]
    public let expectedOut: [[UInt8]]
    private var cursor = 0
    public private(set) var sent: [[UInt8]] = []
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]

    public init(transcript: [TranscriptEntry]) {
        inEntries = transcript.filter { $0.dir == "in" }.map(Transcript.bytes)
        expectedOut = transcript.filter { $0.dir == "out" }.map(Transcript.bytes)
    }

    public func send(_ bytes: [UInt8]) async {
        sent.append(bytes)
    }

    public nonisolated func packets() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            Task { await self.register(continuation) }
        }
    }

    private func register(_ continuation: AsyncStream<[UInt8]>.Continuation) {
        continuations[UUID()] = continuation
    }

    public func playNext(count: Int) {
        for _ in 0..<count where cursor < inEntries.count {
            let bytes = inEntries[cursor]
            cursor += 1
            for continuation in continuations.values { continuation.yield(bytes) }
        }
    }

    public func playAll() {
        playNext(count: inEntries.count - cursor)
    }
}
