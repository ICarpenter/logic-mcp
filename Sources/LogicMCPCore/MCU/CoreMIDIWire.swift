import CoreMIDI
import Foundation

/// Virtual MIDI port pair that Logic sees as a Mackie Control.
public final class CoreMIDIWire: MCUWire, @unchecked Sendable {
    public let portName: String
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()       // daemon → Logic
    private var destination = MIDIEndpointRef()  // Logic → daemon
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]
    private var sysExBuffer: [UInt8] = []

    public init(portName: String = "logic-mcp MCU") throws {
        self.portName = portName
        var status = MIDIClientCreateWithBlock("logic-mcp" as CFString, &client) { _ in }
        guard status == noErr else { throw CoreMIDIError.clientCreate(status) }
        status = MIDISourceCreate(client, portName as CFString, &source)
        guard status == noErr else {
            // `self` is never returned on a throwing init, so nothing else will
            // ever call tearDown() for this half-built instance — dispose what
            // was already created (the client) before throwing.
            MIDIClientDispose(client)
            throw CoreMIDIError.sourceCreate(status)
        }
        status = MIDIDestinationCreateWithBlock(client, portName as CFString, &destination) {
            [weak self] packetList, _ in
            self?.receive(packetList)
        }
        guard status == noErr else {
            // Same reasoning: unwind everything created so far (source, then client).
            MIDIEndpointDispose(source)
            MIDIClientDispose(client)
            throw CoreMIDIError.destinationCreate(status)
        }
    }

    deinit {
        // Fallback for consumers that forget to call tearDown() explicitly, so
        // we don't leak system-visible virtual ports. tearDown() is idempotent,
        // so this is safe even if the consumer already called it.
        tearDown()
    }

    public func tearDown() {
        // Idempotent: zero out each ref after disposing so a second call (an
        // explicit tearDown() followed by deinit's fallback call, or vice
        // versa) doesn't double-dispose.
        if source != 0 {
            MIDIEndpointDispose(source)
            source = MIDIEndpointRef()
        }
        if destination != 0 {
            MIDIEndpointDispose(destination)
            destination = MIDIEndpointRef()
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = MIDIClientRef()
        }
    }

    public func send(_ bytes: [UInt8]) async {
        var builder = MIDIPacketList()
        var packet = MIDIPacketListInit(&builder)
        packet = MIDIPacketListAdd(&builder, 1024, packet, 0, bytes.count, bytes)
        // MIDIPacketListAdd returns null if the event didn't fit in the list
        // (buffer full / add failed). The Swift import claims a non-optional
        // return (the header doesn't annotate nullability), so a plain `!=
        // nil` check is always true; compare the raw bit pattern instead.
        // MCU messages are tiny relative to the 1024-byte buffer, so treat
        // this as a dropped over-size packet rather than calling MIDIReceived
        // with an incomplete/empty list.
        guard Int(bitPattern: packet) != 0 else { return }
        MIDIReceived(source, &builder)   // pushes out of a virtual source
    }

    public func packets() -> AsyncStream<[UInt8]> {
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

    private func yield(_ message: [UInt8]) {
        lock.lock()
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(message) }
    }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>) {
        let numPackets = Int(packetList.pointee.numPackets)
        guard numPackets > 0 else { return }
        // `MIDIPacket` is variable-length in the real buffer (each packet only
        // occupies its header plus `length` bytes, not the full 256-byte
        // `data` field Swift declares). `packetList.pointee.packet` reads a
        // VALUE COPY of just the first packet; passing the address of that
        // local copy to MIDIPacketNext would compute the next-packet offset
        // relative to our own stack frame instead of the real list buffer,
        // corrupting every packet after the first. Instead, derive a pointer
        // into the ACTUAL buffer (packetList's address, offset to the `packet`
        // field) and thread that same pointer identity through MIDIPacketNext
        // for every advance — this is Apple's canonical MIDIPacketList walk.
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        var packetPtr = UnsafeRawPointer(packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<numPackets {
            let packet = packetPtr.pointee
            let count = Int(packet.length)
            let data = withUnsafeBytes(of: packet.data) { raw in
                Array(raw.prefix(count).bindMemory(to: UInt8.self))
            }
            split(data)
            packetPtr = UnsafeRawPointer(MIDIPacketNext(packetPtr)).assumingMemoryBound(to: MIDIPacket.self)
        }
    }

    /// Split a raw packet into complete MIDI messages; reassemble SysEx across packets.
    ///
    /// `sysExBuffer` (mutated below) is only ever touched from this method,
    /// which is only ever called from `receive(_:)`, which is only ever
    /// invoked by the CoreMIDI read callback registered in `init`. CoreMIDI
    /// serializes callback invocations for a given port, so there is no
    /// concurrent access to this buffer and no lock is needed.
    private func split(_ data: [UInt8]) {
        var index = 0
        while index < data.count {
            let byte = data[index]
            if !sysExBuffer.isEmpty {
                // continuing a SysEx
                if let end = data[index...].firstIndex(of: 0xF7) {
                    sysExBuffer += data[index...end]
                    yield(sysExBuffer)
                    sysExBuffer = []
                    index = end + 1
                } else {
                    sysExBuffer += data[index...]
                    return
                }
            } else if byte == 0xF0 {
                if let end = data[index...].firstIndex(of: 0xF7) {
                    yield(Array(data[index...end]))
                    index = end + 1
                } else {
                    sysExBuffer = Array(data[index...])
                    return
                }
            } else {
                let length: Int = switch byte & 0xF0 {
                case 0xC0, 0xD0: 2
                default: 3
                }
                let end = min(index + length, data.count)
                yield(Array(data[index..<end]))
                index = end
            }
        }
    }
}

public enum CoreMIDIError: Error {
    case clientCreate(OSStatus), sourceCreate(OSStatus), destinationCreate(OSStatus)
}
