import XCTest
import MCP
@testable import LogicMCPCore

/// A wire that delivers a command's echo SYNCHRONOUSLY, inside `send()`, before it returns —
/// collapsing the async round-trip latency that `InMemoryWire` (a broadcast log that even
/// REPLAYS to late subscribers) uses to paper over the subscribe-vs-deliver race. A tool that
/// opens its `events()` subscription BEFORE acting catches the echo; a tool that subscribes
/// AFTER acting (the bug) can miss it entirely.
final class SyncEchoWire: MCUWire, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]
    private var muteOn: [Int: Bool] = [:]
    private var ringDelivered: Set<Int> = []

    func send(_ bytes: [UInt8]) async {
        guard let command = MCUCodec.decodeCommand(bytes) else { return }
        switch command {
        case .buttonPress(.mute(let ch)):
            let newState = !(muteOn[ch] ?? false)
            muteOn[ch] = newState
            deliver(MCUCodec.encode(.led(button: .mute(channel: ch), state: newState ? .on : .off)))
        case .vpotTurn(let ch, _):
            // Deliver exactly ONE confirming ring per channel (on the first tick), so a tool
            // that subscribes late can genuinely miss it — a per-tick flood would give a late
            // subscriber many chances and hide the race.
            if ringDelivered.insert(ch).inserted {
                deliver(MCUCodec.encode(.vpotRing(channel: ch, value: 1)))
            }
        default:
            break
        }
    }

    func deliver(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        for c in continuations.values { c.yield(bytes) }
    }

    func packets() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }
}

final class EventRaceTests: XCTestCase {
    private func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
        guard case .text(let json, _, _)? = result.content.first else {
            throw ToolFailure(error: "no text", layer: "daemon")
        }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: - The MCUSession contract this fix depends on

    func testEventsAreLiveOnlyAndDoNotReplay() async {
        let wire = SyncEchoWire()
        let session = MCUSession(wire: wire)
        await session.start()

        // A subscriber opened BEFORE the action catches the synchronously-delivered echo.
        let early = await session.events()
        await session.press(.mute(channel: 0))
        let caught = await MCUSession.first(of: early, timeout: .seconds(1)) {
            if case .led(.mute(0), _) = $0 { return true } else { return false }
        }
        XCTAssertNotNil(caught, "a subscriber opened before the action must catch the echo")

        // Fire another action and let its echo fully drain, THEN subscribe. A live-only stream
        // must NOT replay the already-delivered echo to this late subscriber.
        await session.press(.mute(channel: 1))
        await session.settle(.milliseconds(150))
        let late = await session.events()
        let missed = await MCUSession.first(of: late, timeout: .milliseconds(300)) {
            if case .led(.mute(1), _) = $0 { return true } else { return false }
        }
        XCTAssertNil(missed, "events() is live-only: a late subscriber must not replay a past echo")
    }

    // MARK: - The tools must subscribe BEFORE acting

    // The race is real but only intermittently loses in-process (~1-in-20), so each tool is
    // exercised MANY times: a tool that subscribes AFTER acting misses the echo on some
    // iteration and the loop fails; a tool that subscribes BEFORE acting buffers every echo
    // and passes all iterations deterministically. `on` alternates so each iteration is a real
    // state change that must be LED-confirmed (never a no-op).
    private static let iterations = 120

    /// `set_mute` was re-homed onto AX (Task 5) and no longer opens an MCU event
    /// subscription at all, so it can no longer exercise this race. The retained MCU
    /// `setToggle` free function still has the subscribe-before-press contract this test
    /// guards, so call it directly to keep the regression coverage alive for any future
    /// MCU-toggle caller.
    func testSetMuteAlwaysCatchesSynchronousLEDEcho() async throws {
        for i in 0..<Self.iterations {
            let wire = SyncEchoWire()
            let daemon = await Daemon(wire: wire, axProvider: FakeAXProvider(root: FakeAXNode(role: "AXApplication")))
            await daemon.model.replaceTracks(["Snare"])   // avoid enumeration; index 0, channel 0

            let result = try await setToggle(daemon, trackName: "Snare", on: true,
                                             button: { .mute(channel: $0) },
                                             read: { $0.mute }, write: { $0.mute = $1 }, label: "mute")
            guard case .object(let o) = result else {
                return XCTFail("iteration \(i): expected an object result")
            }
            XCTAssertEqual(o["mute"], .bool(true), "iteration \(i)")
        }
    }

    // `set_pan` was re-homed onto AX (Task 7) and no longer opens an MCU event subscription,
    // presses `.assignPan`, or turns a V-Pot at all — it converges an AX slider directly via
    // `AXBridge.nudgeToRaw` and reads the slider back, never touching the MCU wire. There is
    // no MCU ring-echo race left for it to exercise, and (unlike `setToggle` for mute/solo)
    // there is no retained MCU pan-sweep free function to redirect this regression guard to,
    // so `testSetPanAlwaysCatchesSynchronousRingEcho` — which asserted set_pan must subscribe
    // to MCU events before turning the V-Pot — no longer has anything to guard and was removed,
    // along with the `SyncEchoWire.paintNormalized`/`waitForNormalized` scaffolding it alone
    // used.
}
