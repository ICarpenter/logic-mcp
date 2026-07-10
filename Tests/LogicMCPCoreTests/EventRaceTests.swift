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
    /// When true, paint a normalized per-channel-pan VALUES bottom row on first subscription,
    /// so `SetPanTool.normalizeSurface()` is a no-op and the test reaches the V-Pot sweep.
    private let paintNormalized: Bool

    init(paintNormalized: Bool = false) { self.paintNormalized = paintNormalized }

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
            if paintNormalized {
                let cell = "0".padding(toLength: 7, withPad: " ", startingAt: 0)
                continuation.yield(MCUCodec.encode(.lcd(offset: 56, text: String(repeating: cell, count: 8))))
            }
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

    /// Wait until the session surface reports a per-channel pan VALUES bottom row (the wire's
    /// initial paint has been applied), so set_pan's normalizeSurface will be a no-op.
    private func waitForNormalized(_ session: MCUSession) async {
        for _ in 0..<200 {
            if SurfaceDisplay.isShowingValues(await session.surface.lcdBottom) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
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

    func testSetMuteAlwaysCatchesSynchronousLEDEcho() async throws {
        for i in 0..<Self.iterations {
            let wire = SyncEchoWire()
            let daemon = await Daemon(wire: wire)
            await daemon.model.replaceTracks(["Snare"])   // avoid enumeration; index 0, channel 0
            let registry = ToolRegistry()
            await daemon.registerAllTools(in: registry)

            let result = await registry.call(name: "set_mute",
                                             arguments: ["track": .string("Snare"), "on": .bool(true)])
            XCTAssertNotEqual(result.isError, true,
                              "iteration \(i): set_mute must open its LED subscription BEFORE "
                              + "pressing — a late subscriber misses the echo and fails")
            XCTAssertEqual(try resultJSON(result)["mute"] as? Bool, true, "iteration \(i)")
        }
    }

    func testSetPanAlwaysCatchesSynchronousRingEcho() async throws {
        for i in 0..<Self.iterations {
            let wire = SyncEchoWire(paintNormalized: true)
            let daemon = await Daemon(wire: wire)
            await daemon.model.replaceTracks(["Snare"])   // avoid enumeration; index 0, channel 0
            let registry = ToolRegistry()
            await daemon.registerAllTools(in: registry)
            await waitForNormalized(daemon.session)

            let result = await registry.call(name: "set_pan",
                                             arguments: ["track": .string("Snare"), "position": .int(-20)])
            XCTAssertNotEqual(result.isError, true,
                              "iteration \(i): set_pan must open its V-Pot ring subscription "
                              + "BEFORE sweeping — a late subscriber misses the ring and fails")
        }
    }
}
