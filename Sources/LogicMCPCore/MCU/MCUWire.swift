import Foundation

public protocol MCUWire: Sendable {
    func send(_ bytes: [UInt8]) async
    func packets() -> AsyncStream<[UInt8]>
}

/// In-process wire modeling a broadcast log. Every packet delivered to this end
/// is retained in order; each `packets()` subscriber replays the full history on
/// attach, then receives all subsequent packets live. This makes delivery
/// race-free regardless of when a subscriber attaches relative to the producer
/// (e.g. an `async let` observer set up around a fire-and-forget emit): no packet
/// is ever lost to a subscribe-vs-deliver timing window, and each subscriber sees
/// every packet exactly once. `pair()` cross-connects two ends. Test-only
/// transport (production uses `CoreMIDIWire`), so the unbounded log is fine.
public final class InMemoryWire: MCUWire, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]
    private var peer: InMemoryWire?
    private var log: [[UInt8]] = []   // every packet ever delivered to this end, in order

    public init() {}

    public static func pair() -> (daemonEnd: InMemoryWire, logicEnd: InMemoryWire) {
        let a = InMemoryWire()
        let b = InMemoryWire()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ bytes: [UInt8]) async {
        peer?.deliver(bytes)
    }

    func deliver(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        log.append(bytes)
        for continuation in continuations.values { continuation.yield(bytes) }
    }

    public func packets() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let id = UUID()
            // Replay the full history to this subscriber, then register it — all
            // under one lock so a concurrent deliver either lands in the replayed
            // history or is yielded live strictly after, never both, never lost.
            lock.lock()
            for bytes in log { continuation.yield(bytes) }
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }
}
