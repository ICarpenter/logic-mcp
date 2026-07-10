import ArgumentParser
import Foundation
import LogicMCPCore
import MCP

@main
struct LogicMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logic-mcp",
        abstract: "MCP server giving agents end-to-end control of Logic Pro.",
        subcommands: [Serve.self, Capture.self, Probe.self, Calibrate.self, LCDProbe.self, AXDump.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the MCP server on stdio.")

    func run() async throws {
        let wire = try CoreMIDIWire()
        // SystemAXProvider's init never throws for missing Logic/permission — it stores a
        // nil app and AX tools fail gracefully (ToolFailure(layer: "ax")) at call time.
        let axProvider = try SystemAXProvider()
        let daemon = await Daemon(wire: wire, axProvider: axProvider)
        let registry = ToolRegistry()
        await daemon.registerAllTools(in: registry)

        let server = Server(
            name: "logic-mcp",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: await registry.list())
        }
        await server.withMethodHandler(CallTool.self) { params in
            await registry.call(name: params.name, arguments: params.arguments)
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a bidirectional MCU transcript from a live Logic session to JSONL.")

    @Option(name: .long, help: "Output transcript path.")
    var out: String

    func run() async throws {
        let wire = try CoreMIDIWire()
        let url = URL(fileURLWithPath: out)
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        // A recording wrapper: logs "out" for daemon-sent, "in" for Logic-sent.
        let session = MCUSession(wire: RecordingWire(base: wire, handle: handle))
        await session.start()
        FileHandle.standardError.write(Data("capturing on '\(wire.portName)' — Ctrl-C to stop\n".utf8))
        try await Task.sleep(for: .seconds(86400))
    }
}

/// Wraps a wire; tees both directions into a transcript file.
final class RecordingWire: MCUWire, @unchecked Sendable {
    let base: CoreMIDIWire
    let handle: FileHandle
    let lock = NSLock()

    init(base: CoreMIDIWire, handle: FileHandle) {
        self.base = base
        self.handle = handle
    }

    func log(_ dir: String, _ bytes: [UInt8]) {
        let entry = TranscriptEntry(dir: dir, hex: Transcript.hex(bytes))
        let line = String(data: try! JSONEncoder().encode(entry), encoding: .utf8)! + "\n"
        lock.lock()
        handle.write(Data(line.utf8))
        lock.unlock()
    }

    func send(_ bytes: [UInt8]) async {
        log("out", bytes)
        await base.send(bytes)
    }

    func packets() -> AsyncStream<[UInt8]> {
        let upstream = base.packets()
        return AsyncStream { continuation in
            Task {
                for await packet in upstream {
                    self.log("in", packet)
                    continuation.yield(packet)
                }
                continuation.finish()
            }
        }
    }
}
