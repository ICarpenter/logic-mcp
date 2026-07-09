import XCTest
import CoreMIDI
@testable import LogicMCPCore

final class CoreMIDIWireTests: XCTestCase {
    /// Round-trip through the real CoreMIDI server: a second in-process client
    /// connects to our virtual source and sends to our virtual destination.
    func testLoopbackThroughVirtualPorts() async throws {
        let wire = try CoreMIDIWire(portName: "logic-mcp test \(UUID().uuidString.prefix(8))")
        defer { wire.tearDown() }

        // Find our virtual destination and send it 3 bytes as an external client would.
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("test-client" as CFString, &client) { _ in }
        defer { MIDIClientDispose(client) }
        var outPort = MIDIPortRef()
        MIDIOutputPortCreate(client, "test-out" as CFString, &outPort)

        guard let dest = (0..<MIDIGetNumberOfDestinations())
            .map({ MIDIGetDestination($0) })
            .first(where: { endpointName($0) == wire.portName }) else {
            return XCTFail("virtual destination not found")
        }

        let stream = wire.packets()
        var builder = MIDIPacketList()
        var packet = MIDIPacketListInit(&builder)
        let bytes: [UInt8] = [0x90, 0x5E, 0x7F]
        packet = MIDIPacketListAdd(&builder, 1024, packet, 0, bytes.count, bytes)
        MIDISend(outPort, dest, &builder)

        let received = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        XCTAssertEqual(received, [0x90, 0x5E, 0x7F])
    }

    /// send() direction (daemon → Logic): an external client creates an input
    /// port, connects it to our virtual SOURCE, and should receive exactly the
    /// bytes passed to `wire.send(_:)`.
    func testSendDeliversToConnectedExternalListener() async throws {
        let wire = try CoreMIDIWire(portName: "logic-mcp test \(UUID().uuidString.prefix(8))")
        defer { wire.tearDown() }

        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("test-client-send" as CFString, &client) { _ in }
        defer { MIDIClientDispose(client) }

        let sink = TestPacketSink()
        var inPort = MIDIPortRef()
        let createStatus = MIDIInputPortCreateWithBlock(
            client, "test-in" as CFString, &inPort
        ) { packetList, _ in
            sink.receive(packetList)
        }
        XCTAssertEqual(createStatus, noErr)
        defer { MIDIPortDispose(inPort) }

        guard let src = (0..<MIDIGetNumberOfSources())
            .map({ MIDIGetSource($0) })
            .first(where: { endpointName($0) == wire.portName }) else {
            return XCTFail("virtual source not found")
        }

        let connectStatus = MIDIPortConnectSource(inPort, src, nil)
        XCTAssertEqual(connectStatus, noErr)
        defer { MIDIPortDisconnectSource(inPort, src) }

        // Register the listener stream before sending, so there's no window
        // where a fast delivery could arrive before we're subscribed.
        let stream = sink.stream()
        let bytes: [UInt8] = [0x90, 0x10, 0x7F]
        await wire.send(bytes)

        let received = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        XCTAssertEqual(received, bytes)
    }

    /// Multi-packet parse: a single MIDIPacketList containing 2 short MIDI
    /// messages, delivered in one MIDISend, must be split into both messages
    /// in order. Exercises the MIDIPacketNext advance across packets.
    ///
    /// Note: this is a smoke test of the multi-packet path, NOT a discriminating
    /// regression test for the by-value-copy bug that `receive()`'s pointer walk
    /// fixes. Because `MIDIPacket.data` is a fixed 256-byte field, a by-value copy
    /// of the first packet incidentally also captures the bytes of following small
    /// packets, so the *old* buggy advance produced correct output for cases this
    /// small too (verified empirically during review). The correctness of the
    /// pointer-based advance rests on code review against the CoreMIDI SDK
    /// semantics; a truly discriminating test would need a heap-allocated list
    /// whose later packets fall beyond the first packet's 256-byte data window.
    func testMultiPacketListIsParsedInOrder() async throws {
        let wire = try CoreMIDIWire(portName: "logic-mcp test \(UUID().uuidString.prefix(8))")
        defer { wire.tearDown() }

        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("test-client-multi" as CFString, &client) { _ in }
        defer { MIDIClientDispose(client) }
        var outPort = MIDIPortRef()
        MIDIOutputPortCreate(client, "test-out-multi" as CFString, &outPort)

        guard let dest = (0..<MIDIGetNumberOfDestinations())
            .map({ MIDIGetDestination($0) })
            .first(where: { endpointName($0) == wire.portName }) else {
            return XCTFail("virtual destination not found")
        }

        let stream = wire.packets()

        // Heads-up for future extenders: `builder` is a stack MIDIPacketList
        // (~272 bytes = one 256-byte-data packet). The 1024 passed to
        // MIDIPacketListAdd below is a LIE about the real capacity — it's safe
        // ONLY because these two packets are tiny. Adding many/large packets here
        // will overflow the stack variable and corrupt the stack. To grow this,
        // heap-allocate the list (UnsafeMutableRawPointer.allocate) sized to match.
        var builder = MIDIPacketList()
        var packet = MIDIPacketListInit(&builder)
        let first: [UInt8] = [0x90, 0x10, 0x7F]
        let second: [UInt8] = [0x90, 0x5E, 0x7F]
        // MIDIPacketListAdd requires ascending timestamps across packets in a
        // list; equal/non-increasing timestamps make it silently no-op
        // (same pointer, no increment) rather than fail, so use 0 then 1.
        packet = MIDIPacketListAdd(&builder, 1024, packet, 0, first.count, first)
        XCTAssertNotNil(packet)
        packet = MIDIPacketListAdd(&builder, 1024, packet, 1, second.count, second)
        XCTAssertNotNil(packet)
        XCTAssertEqual(builder.numPackets, 2)
        MIDISend(outPort, dest, &builder)

        let received = await withTaskGroup(of: [[UInt8]].self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                var messages: [[UInt8]] = []
                while messages.count < 2, let next = await iterator.next() {
                    messages.append(next)
                }
                return messages
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return []
            }
            let winner = await group.next() ?? []
            group.cancelAll()
            return winner
        }
        XCTAssertEqual(received, [first, second])
    }
}

private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
    return (name?.takeRetainedValue() as String?) ?? ""
}

/// Test-only helper: receives MIDIPacketLists from a CoreMIDI input-port
/// block callback (an arbitrary CoreMIDI thread) and exposes them as an
/// AsyncStream, mirroring CoreMIDIWire's own continuation fan-out. Only ever
/// asked to parse single, short packets in these tests (wire.send() adds
/// exactly one packet per call), so a direct first-packet extraction is
/// sufficient here — the multi-packet walk under test lives in
/// CoreMIDIWire.receive(_:), not in this test harness.
private final class TestPacketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]

    func stream() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
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

    func receive(_ packetList: UnsafePointer<MIDIPacketList>) {
        let packet = packetList.pointee.packet
        let count = Int(packet.length)
        let bytes = withUnsafeBytes(of: packet.data) { raw in
            Array(raw.prefix(count).bindMemory(to: UInt8.self))
        }
        lock.lock()
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(bytes) }
    }
}
