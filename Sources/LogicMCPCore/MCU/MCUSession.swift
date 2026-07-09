import Foundation

public struct SurfaceState: Sendable {
    public var lcdTop = String(repeating: " ", count: 56)
    public var lcdBottom = String(repeating: " ", count: 56)
    public var faderRaw = [Int](repeating: -1, count: 9)
    public var leds: [MCUButton: LEDState] = [:]
    public var connected = false

    public func lcdCell(line: Int, channel: Int) -> String {
        let source = line == 0 ? lcdTop : lcdBottom
        let start = source.index(source.startIndex, offsetBy: channel * 7)
        let end = source.index(start, offsetBy: 7)
        return String(source[start..<end])
    }

    mutating func write(offset: Int, text: String) {
        var chars = Array((lcdTop + lcdBottom))
        for (i, ch) in text.enumerated() where offset + i < 112 {
            chars[offset + i] = ch
        }
        lcdTop = String(chars[0..<56])
        lcdBottom = String(chars[56..<112])
    }
}

public actor MCUSession {
    private let wire: MCUWire
    private let serial: [UInt8]
    public private(set) var surface = SurfaceState()
    private var continuations: [UUID: AsyncStream<MCUEvent>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    public init(wire: MCUWire, serial: [UInt8] = Array("LMCP001".utf8)) {
        self.wire = wire
        self.serial = serial
    }

    public func start() {
        guard pump == nil else { return }
        let stream = wire.packets()
        pump = Task { [weak self] in
            for await packet in stream {
                guard let self else { break }
                guard let event = MCUCodec.decodeEvent(packet) else { continue }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: MCUEvent) async {
        switch event {
        case .deviceQuery:
            await wire.send(MCUCodec.encode(
                MCUCommand.hostConnectionQuery(serial: serial, challenge: [1, 2, 3, 4])))
        case .hostConnectionReply:
            await wire.send(MCUCodec.encode(MCUCommand.connectionConfirmation(serial: serial)))
            surface.connected = true
        case .lcd(let offset, let text):
            surface.connected = true
            surface.write(offset: offset, text: text)
        case .faderEcho(let ch, let value):
            if ch < surface.faderRaw.count { surface.faderRaw[ch] = value }
        case .led(let button, let state):
            surface.leds[button] = state
        case .vpotRing, .timecodeDigit, .meter:
            break
        }
        for continuation in continuations.values { continuation.yield(event) }
    }

    public func events() -> AsyncStream<MCUEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func press(_ button: MCUButton) async {
        await wire.send(MCUCodec.encode(MCUCommand.buttonPress(button)))
        try? await Task.sleep(for: .milliseconds(10))
        await wire.send(MCUCodec.encode(MCUCommand.buttonRelease(button)))
    }

    public func turnVPot(channel: Int, ticks: Int) async {
        // MCU deltas are capped at ±7 per message; chunk larger turns.
        var remaining = ticks
        while remaining != 0 {
            let step = max(-7, min(7, remaining))
            await wire.send(MCUCodec.encode(MCUCommand.vpotTurn(channel: channel, ticks: step)))
            remaining -= step
        }
    }

    public func moveFader(channel: Int, toRaw target: Int, timeout: Duration) async throws -> Int {
        let stream = events()
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: true)))
        await wire.send(MCUCodec.encode(MCUCommand.faderMove(channel: channel, value: target)))
        await wire.send(MCUCodec.encode(MCUCommand.faderTouch(channel: channel, touched: false)))
        let echoed = await Self.first(of: stream, timeout: timeout) {
            if case .faderEcho(channel, _) = $0 { return true } else { return false }
        }
        guard case .faderEcho(_, let value)? = echoed else {
            throw ToolFailure(error: "no fader echo", layer: "mcu",
                              expected: "fader echo on channel \(channel) within \(timeout)",
                              observed: "no response from Logic")
        }
        return value
    }

    public func waitFor(timeout: Duration,
                        _ predicate: @escaping @Sendable (MCUEvent) -> Bool) async -> MCUEvent? {
        await Self.first(of: events(), timeout: timeout, where: predicate)
    }

    public func settle(_ quiet: Duration) async {
        while await waitFor(timeout: quiet, { _ in true }) != nil {}
    }

    private static func first(of stream: AsyncStream<MCUEvent>, timeout: Duration,
                              where predicate: @escaping @Sendable (MCUEvent) -> Bool) async -> MCUEvent? {
        await withTaskGroup(of: MCUEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }
}
