# logic-mcp Phase 1 — MCUBridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `logic-mcp` daemon (Swift, MCP over stdio) that controls Logic Pro's mixer, transport, and plugin parameters via Mackie Control emulation over virtual CoreMIDI ports — the "mix moves via chat" demo slice.

**Architecture:** A `LogicMCPCore` library holds everything testable: a pure MCU protocol codec, an `MCUSession` state machine over an abstract `MCUWire` transport, a `ProjectModel` shadow state actor, and MCP tools that act → verify (MCU echo) → report. A thin `logic-mcp` executable wires the core to the official Swift MCP SDK over stdio and to real CoreMIDI virtual ports. Unit tests run against a `FakeLogic` simulator and recorded transcripts; real Logic is exercised by a documented integration smoke run.

**Tech Stack:** Swift 6.0, Swift Package Manager, macOS 14+, [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.11.x (`MCP` product), swift-argument-parser 1.5.x, CoreMIDI, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-08-logic-mcp-design.md` — this plan implements the MCUBridge layer plus shadow model v0 and the MCU-scoped tool surface. FileGateway, AXDriver, VisionVerifier, skill packs, and checkpoints get their own plans (see "Later phases" at the bottom).

## Global Constraints

- **No commits by implementers.** The user controls all commits (CLAUDE.md). Tasks end at "tests pass"; never run `git commit`.
- **Verified ground truth.** Every mutating tool returns the value Logic echoed back over the MCU wire, never the value we sent. No echo within timeout ⇒ structured error.
- **Structured errors.** All tool failures are `ToolFailure { error, layer, expected, observed }` serialized as the JSON body of an `isError: true` MCP result.
- **`record` never arms itself.** The tool requires `confirm: true` and its description states it must only be called on explicit user request.
- **No focus stealing.** Nothing in this phase touches window focus, Accessibility, or screen capture. MIDI only — no macOS permissions needed.
- **No reverse-engineered internals.** MCU protocol only (publicly documented in the Emagic Logic Control manual's MIDI implementation appendix); no Logic Remote protocol, no `.logicx` writes.
- **Swift 6 strict concurrency.** All shared state lives in actors; types crossing actor boundaries are `Sendable`.
- **MCU SysEx header is `F0 00 00 66 14`** (Mackie Control Universal, device id `0x14`) throughout.

## File Structure

```
Package.swift
Sources/LogicMCPCore/
  MCU/MCUButton.swift        # button/LED note-number map
  MCU/MCUCodec.swift         # bytes ⇄ MCUCommand / MCUEvent (pure)
  MCU/FaderCurve.swift       # 14-bit fader position ⇄ dB
  MCU/MCUWire.swift          # transport protocol + InMemoryWire pair
  MCU/CoreMIDIWire.swift     # virtual CoreMIDI ports
  MCU/MCUSession.swift       # state machine: LCD, echoes, LEDs, handshake
  Model/ProjectModel.swift   # shadow model v0 (tracks, transport)
  Model/MixerNavigator.swift # banking, track enumeration, name resolution
  Model/UndoJournal.swift    # mutation log + deterministic undo
  Support/Transcript.swift   # JSONL transcript read/write + ScriptedWire
  Tools/ToolRegistry.swift   # LogicTool protocol, ToolFailure, registry
  Tools/PingTool.swift
  Tools/QueryTools.swift     # get_project_overview, get_track, refresh_state
  Tools/TransportTools.swift # play, stop, record, toggle_cycle, locate
  Tools/MixTools.swift       # set_volume, set_pan, set_mute, set_solo, set_automation_mode
  Tools/SendTools.swift      # set_send
  Tools/PluginTools.swift    # get_plugin_params, set_plugin_param
  Tools/UndoTool.swift       # undo_last
Sources/logic-mcp/
  Main.swift                 # ArgumentParser root: serve (default), capture
Tests/LogicMCPCoreTests/
  MCUCodecTests.swift
  FaderCurveTests.swift
  TranscriptTests.swift
  FakeLogic.swift            # in-process Logic simulator (test double)
  FakeLogicTests.swift
  CoreMIDIWireTests.swift
  MCUSessionTests.swift
  ProjectModelTests.swift
  ToolTests.swift            # per-tool end-to-end tests against FakeLogic
  Fixtures/                  # transcript fixtures (JSONL)
Scripts/smoke-stdio.sh       # stdio JSON-RPC smoke test
docs/integration-smoke.md    # manual real-Logic gate (written in Task 16)
```

Naming: `snake_case` for MCP tool names (matches spec), Swift API in the usual `camelCase`.

## MCU protocol reference (used by Tasks 2–14)

All on the surface's single MIDI port pair. "→" = daemon (surface) to Logic; "←" = Logic to daemon.

| Thing | Wire format |
|---|---|
| Fader move →, fader echo ← | Pitch bend, MIDI channel *n* = fader *n* (0–7, 8 = master): `En ll hh`, 14-bit value 0–16383 |
| Fader touch → | Note `0x68+n` (master `0x70`), velocity `0x7F` touch / `0x00` release |
| Buttons → , LEDs ← | Note on channel 1: `90 nn 7F` press / `90 nn 00` release; LED ←: velocity `0x7F` on, `0x00` off, `0x01` blink |
| V-Pot turn → | CC `B0 1n vv`: `n` = pot 0–7, `vv` = `0x01–0x07` clockwise ticks, `0x41–0x47` counter-clockwise |
| V-Pot ring ← | CC `B0 3n vv` |
| LCD ← | SysEx `F0 00 00 66 14 12 <offset 0–111> <ASCII…> F7`; offsets 0–55 top line, 56–111 bottom line; 8 channels × 7 chars per line |
| Timecode ← | CC `B0 4i vv`, digit index `i` = 0–9 right-to-left; low 6 bits of `vv` = char (`(vv & 0x3F) < 0x20 ? +0x40 : +0x00` to ASCII), bit 6 = dot |
| Meters ← | Channel pressure `D0 xv`: high nibble = channel, low nibble = level |
| Handshake | ← Device query `F0 00 00 66 14 00 F7`; → Host connection query `… 01 <7-byte serial> <4-byte challenge> F7`; ← Host connection reply `… 02 <serial> <response> F7`; → Connection confirmation `… 03 <serial> F7` |

Button note numbers (channel-strip buttons take channel 0–7): REC `0x00+ch`, SOLO `0x08+ch`, MUTE `0x10+ch`, SELECT `0x18+ch`, V-Pot press `0x20+ch`. Assignment: TRACK `0x28`, SEND `0x29`, PAN `0x2A`, PLUGIN `0x2B`, EQ `0x2C`, INSTRUMENT `0x2D`. BANK− `0x2E`, BANK+ `0x2F`, CHANNEL− `0x30`, CHANNEL+ `0x31`, FLIP `0x32`, GLOBAL `0x33`, NAME/VALUE `0x34`, SMPTE/BEATS `0x35`. F1–F8 `0x36–0x3D`. Automation: READ `0x4A`, WRITE `0x4B`, TRIM `0x4C`, TOUCH `0x4D`, LATCH `0x4E`. SAVE `0x50`, UNDO `0x51`, CANCEL `0x52`, ENTER `0x53`. MARKER `0x54`, NUDGE `0x55`, CYCLE `0x56`, DROP `0x57`, REPLACE `0x58`, CLICK `0x59`, GLOBAL SOLO `0x5A`. Transport: REW `0x5B`, FF `0x5C`, STOP `0x5D`, PLAY `0x5E`, RECORD `0x5F`. Cursor `0x60–0x63`, ZOOM `0x64`, SCRUB `0x65`. Jog wheel: CC `B0 3C vv` (delta-coded like V-Pots).

---

### Task 1: Package scaffold + MCP stdio server with `ping`

**Files:**
- Create: `Package.swift`
- Create: `Sources/LogicMCPCore/Tools/ToolRegistry.swift`
- Create: `Sources/LogicMCPCore/Tools/PingTool.swift`
- Create: `Sources/logic-mcp/Main.swift`
- Create: `Tests/LogicMCPCoreTests/ToolTests.swift`
- Create: `Scripts/smoke-stdio.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `protocol LogicTool { var name: String; var description: String; var inputSchema: Value; func invoke(_ args: [String: Value]) async throws -> Value }`; `struct ToolFailure: Error, Codable { var error: String; var layer: String; var expected: String?; var observed: String? }`; `actor ToolRegistry { func register(_: LogicTool); func list() -> [Tool]; func call(name: String, arguments: [String: Value]?) async -> CallTool.Result }`. Every later tool task registers through this.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "logic-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "LogicMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "logic-mcp",
            dependencies: [
                "LogicMCPCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LogicMCPCoreTests",
            dependencies: ["LogicMCPCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/LogicMCPCoreTests/ToolTests.swift`:

```swift
import XCTest
import MCP
@testable import LogicMCPCore

final class ToolTests: XCTestCase {
    func testPingReturnsOkAndVersion() async throws {
        let registry = ToolRegistry()
        await registry.register(PingTool(version: "0.1.0"))
        let result = await registry.call(name: "ping", arguments: [:])
        XCTAssertNotEqual(result.isError, true)
        guard case .text(let json)? = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("0.1.0"))
    }

    func testUnknownToolIsStructuredError() async throws {
        let registry = ToolRegistry()
        let result = await registry.call(name: "nope", arguments: nil)
        XCTAssertEqual(result.isError, true)
        guard case .text(let json)? = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(json.contains("\"layer\":\"daemon\""))
    }
}
```

Note: if the SDK's `Tool.Content` text case pattern differs (e.g. carries annotations), adjust the `guard case` to match — check `.build/checkouts/swift-sdk` sources once fetched.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: compile failure — `ToolRegistry` and `PingTool` don't exist yet.

- [ ] **Step 4: Implement registry and ping**

`Sources/LogicMCPCore/Tools/ToolRegistry.swift`:

```swift
import Foundation
import MCP

public protocol LogicTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: Value { get }
    func invoke(_ args: [String: Value]) async throws -> Value
}

/// The spec's structured error contract: {error, layer, expected, observed}.
public struct ToolFailure: Error, Codable, Sendable {
    public var error: String
    public var layer: String   // "mcu" | "model" | "daemon"
    public var expected: String?
    public var observed: String?

    public init(error: String, layer: String, expected: String? = nil, observed: String? = nil) {
        self.error = error
        self.layer = layer
        self.expected = expected
        self.observed = observed
    }

    var json: String {
        let data = try! JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

public actor ToolRegistry {
    private var tools: [String: LogicTool] = [:]

    public init() {}

    public func register(_ tool: LogicTool) {
        tools[tool.name] = tool
    }

    public func list() -> [Tool] {
        tools.values
            .sorted { $0.name < $1.name }
            .map { Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let tool = tools[name] else {
            let failure = ToolFailure(error: "unknown tool '\(name)'", layer: "daemon")
            return .init(content: [.text(failure.json)], isError: true)
        }
        do {
            let value = try await tool.invoke(arguments ?? [:])
            let data = try JSONEncoder().encode(value)
            return .init(content: [.text(String(data: data, encoding: .utf8)!)], isError: false)
        } catch let failure as ToolFailure {
            return .init(content: [.text(failure.json)], isError: true)
        } catch {
            let failure = ToolFailure(error: String(describing: error), layer: "daemon")
            return .init(content: [.text(failure.json)], isError: true)
        }
    }
}
```

`Sources/LogicMCPCore/Tools/PingTool.swift`:

```swift
import MCP

public struct PingTool: LogicTool {
    public let name = "ping"
    public let description = "Health check. Returns daemon version."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])
    let version: String

    public init(version: String) { self.version = version }

    public func invoke(_ args: [String: Value]) async throws -> Value {
        .object(["ok": .bool(true), "version": .string(version)])
    }
}
```

If `Content.text` requires labeled arguments in this SDK version (`.text(text:annotations:_meta:)`), wrap it once in a `private func textContent(_ s: String)` helper inside `ToolRegistry` and use it everywhere.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`, 2 tests.

- [ ] **Step 6: Wire the executable**

`Sources/logic-mcp/Main.swift`:

```swift
import ArgumentParser
import Foundation
import LogicMCPCore
import MCP

@main
struct LogicMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logic-mcp",
        abstract: "MCP server giving agents end-to-end control of Logic Pro.",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the MCP server on stdio.")

    func run() async throws {
        let registry = ToolRegistry()
        await registry.register(PingTool(version: "0.1.0"))

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
```

- [ ] **Step 7: Write and run the stdio smoke script**

`Scripts/smoke-stdio.sh` (then `chmod +x Scripts/smoke-stdio.sh`):

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=".build/debug/logic-mcp"
OUT=$( (printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ping","arguments":{}}}'; sleep 1) | "$BIN" serve )
if echo "$OUT" | grep -q '\\"ok\\":true'; then
  echo "SMOKE PASS"
else
  echo "SMOKE FAIL"; echo "$OUT"; exit 1
fi
```

Run: `./Scripts/smoke-stdio.sh`
Expected: `SMOKE PASS`. (The grep matches the escaped JSON inside the MCP text content.)

- [ ] **Step 8: Stop — task complete, do not commit** (user controls commits).

---

### Task 2: MCU protocol codec

**Files:**
- Create: `Sources/LogicMCPCore/MCU/MCUButton.swift`
- Create: `Sources/LogicMCPCore/MCU/MCUCodec.swift`
- Test: `Tests/LogicMCPCoreTests/MCUCodecTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MCUButton: Equatable, Hashable, Sendable` with `var note: UInt8` and `init?(note: UInt8)`.
  - `enum MCUCommand` (surface → Logic): `.faderMove(channel: Int, value: Int)`, `.faderTouch(channel: Int, touched: Bool)`, `.buttonPress(MCUButton)`, `.buttonRelease(MCUButton)`, `.vpotTurn(channel: Int, ticks: Int)`, `.hostConnectionQuery(serial: [UInt8], challenge: [UInt8])`, `.connectionConfirmation(serial: [UInt8])`.
  - `enum MCUEvent` (Logic → surface): `.faderEcho(channel: Int, value: Int)`, `.lcd(offset: Int, text: String)`, `.led(button: MCUButton, state: LEDState)`, `.vpotRing(channel: Int, value: Int)`, `.timecodeDigit(index: Int, char: Character)`, `.meter(channel: Int, level: Int)`, `.deviceQuery`, `.hostConnectionReply(serial: [UInt8])`.
  - `enum LEDState: Sendable { case off, on, blink }`
  - `enum MCUCodec`: `static func encode(_: MCUCommand) -> [UInt8]`, `static func encode(_: MCUEvent) -> [UInt8]`, `static func decodeEvent(_: [UInt8]) -> MCUEvent?`, `static func decodeCommand(_: [UInt8]) -> MCUCommand?`. (Both directions are public: the daemon decodes events; `FakeLogic` and tests decode commands.)

- [ ] **Step 1: Write the failing tests**

`Tests/LogicMCPCoreTests/MCUCodecTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class MCUCodecTests: XCTestCase {
    func testFaderMoveEncodesAsPitchBend() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.faderMove(channel: 0, value: 8192)),
                       [0xE0, 0x00, 0x40])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.faderMove(channel: 7, value: 16383)),
                       [0xE7, 0x7F, 0x7F])
    }

    func testFaderEchoDecodes() {
        guard case .faderEcho(let ch, let v)? = MCUCodec.decodeEvent([0xE2, 0x10, 0x20]) else {
            return XCTFail("expected faderEcho")
        }
        XCTAssertEqual(ch, 2)
        XCTAssertEqual(v, (0x20 << 7) | 0x10)  // 4112
    }

    func testLCDSysExDecodes() {
        var bytes: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 56]
        bytes += Array("Vocal  ".utf8)
        bytes.append(0xF7)
        guard case .lcd(let offset, let text)? = MCUCodec.decodeEvent(bytes) else {
            return XCTFail("expected lcd")
        }
        XCTAssertEqual(offset, 56)
        XCTAssertEqual(text, "Vocal  ")
    }

    func testButtonRoundTrip() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.buttonPress(.play)), [0x90, 0x5E, 0x7F])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.buttonRelease(.mute(channel: 3))), [0x90, 0x13, 0x00])
        guard case .buttonPress(let b)? = MCUCodec.decodeCommand([0x90, 0x2E, 0x7F]) else {
            return XCTFail("expected press")
        }
        XCTAssertEqual(b, .bankLeft)
    }

    func testLEDDecodes() {
        guard case .led(let b, let s)? = MCUCodec.decodeEvent([0x90, 0x10, 0x7F]) else {
            return XCTFail("expected led")
        }
        XCTAssertEqual(b, .mute(channel: 0))
        XCTAssertEqual(s, .on)
        guard case .led(_, let blink)? = MCUCodec.decodeEvent([0x90, 0x5E, 0x01]) else {
            return XCTFail("expected led")
        }
        XCTAssertEqual(blink, .blink)
    }

    func testVPotTurnEncodesDelta() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.vpotTurn(channel: 0, ticks: 3)), [0xB0, 0x10, 0x03])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.vpotTurn(channel: 5, ticks: -2)), [0xB0, 0x15, 0x42])
    }

    func testHandshakeDecode() {
        XCTAssertNotNil(MCUCodec.decodeEvent([0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7]))
        guard case .deviceQuery? = MCUCodec.decodeEvent([0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7]) else {
            return XCTFail("expected deviceQuery")
        }
    }

    func testTimecodeDigitDecodes() {
        // 0xB0 0x40 0x30 → rightmost digit '0'
        guard case .timecodeDigit(let idx, let ch)? = MCUCodec.decodeEvent([0xB0, 0x40, 0x30]) else {
            return XCTFail("expected timecodeDigit")
        }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(ch, "0")
    }

    func testMeterDecodes() {
        guard case .meter(let ch, let lvl)? = MCUCodec.decodeEvent([0xD0, 0x3C]) else {
            return XCTFail("expected meter")
        }
        XCTAssertEqual(ch, 3)
        XCTAssertEqual(lvl, 12)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCUCodecTests 2>&1 | tail -5`
Expected: compile failure — types don't exist.

- [ ] **Step 3: Implement `MCUButton`**

`Sources/LogicMCPCore/MCU/MCUButton.swift`:

```swift
/// Mackie Control button ↔ note-number map (Logic Control MIDI implementation).
public enum MCUButton: Equatable, Hashable, Sendable {
    case recArm(channel: Int)      // 0x00 + ch
    case solo(channel: Int)        // 0x08 + ch
    case mute(channel: Int)        // 0x10 + ch
    case select(channel: Int)      // 0x18 + ch
    case vpotPress(channel: Int)   // 0x20 + ch
    case assignTrack, assignSend, assignPan, assignPlugin, assignEQ, assignInstrument // 0x28–0x2D
    case bankLeft, bankRight, channelLeft, channelRight                                // 0x2E–0x31
    case flip, global, nameValue, smpteBeats                                           // 0x32–0x35
    case function(Int)             // F1–F8 → 0x36 + (n-1)
    case automationRead, automationWrite, automationTrim, automationTouch, automationLatch // 0x4A–0x4E
    case save, undo, cancel, enter                                                     // 0x50–0x53
    case marker, nudge, cycle, drop, replace, click, globalSolo                        // 0x54–0x5A
    case rewind, fastForward, stop, play, record                                       // 0x5B–0x5F
    case cursorUp, cursorDown, cursorLeft, cursorRight, zoom, scrub                    // 0x60–0x65

    public var note: UInt8 {
        switch self {
        case .recArm(let c): return UInt8(0x00 + c)
        case .solo(let c): return UInt8(0x08 + c)
        case .mute(let c): return UInt8(0x10 + c)
        case .select(let c): return UInt8(0x18 + c)
        case .vpotPress(let c): return UInt8(0x20 + c)
        case .assignTrack: return 0x28
        case .assignSend: return 0x29
        case .assignPan: return 0x2A
        case .assignPlugin: return 0x2B
        case .assignEQ: return 0x2C
        case .assignInstrument: return 0x2D
        case .bankLeft: return 0x2E
        case .bankRight: return 0x2F
        case .channelLeft: return 0x30
        case .channelRight: return 0x31
        case .flip: return 0x32
        case .global: return 0x33
        case .nameValue: return 0x34
        case .smpteBeats: return 0x35
        case .function(let n): return UInt8(0x36 + (n - 1))
        case .automationRead: return 0x4A
        case .automationWrite: return 0x4B
        case .automationTrim: return 0x4C
        case .automationTouch: return 0x4D
        case .automationLatch: return 0x4E
        case .save: return 0x50
        case .undo: return 0x51
        case .cancel: return 0x52
        case .enter: return 0x53
        case .marker: return 0x54
        case .nudge: return 0x55
        case .cycle: return 0x56
        case .drop: return 0x57
        case .replace: return 0x58
        case .click: return 0x59
        case .globalSolo: return 0x5A
        case .rewind: return 0x5B
        case .fastForward: return 0x5C
        case .stop: return 0x5D
        case .play: return 0x5E
        case .record: return 0x5F
        case .cursorUp: return 0x60
        case .cursorDown: return 0x61
        case .cursorLeft: return 0x62
        case .cursorRight: return 0x63
        case .zoom: return 0x64
        case .scrub: return 0x65
        }
    }

    public init?(note: UInt8) {
        switch note {
        case 0x00...0x07: self = .recArm(channel: Int(note))
        case 0x08...0x0F: self = .solo(channel: Int(note) - 0x08)
        case 0x10...0x17: self = .mute(channel: Int(note) - 0x10)
        case 0x18...0x1F: self = .select(channel: Int(note) - 0x18)
        case 0x20...0x27: self = .vpotPress(channel: Int(note) - 0x20)
        case 0x28: self = .assignTrack
        case 0x29: self = .assignSend
        case 0x2A: self = .assignPan
        case 0x2B: self = .assignPlugin
        case 0x2C: self = .assignEQ
        case 0x2D: self = .assignInstrument
        case 0x2E: self = .bankLeft
        case 0x2F: self = .bankRight
        case 0x30: self = .channelLeft
        case 0x31: self = .channelRight
        case 0x32: self = .flip
        case 0x33: self = .global
        case 0x34: self = .nameValue
        case 0x35: self = .smpteBeats
        case 0x36...0x3D: self = .function(Int(note) - 0x36 + 1)
        case 0x4A: self = .automationRead
        case 0x4B: self = .automationWrite
        case 0x4C: self = .automationTrim
        case 0x4D: self = .automationTouch
        case 0x4E: self = .automationLatch
        case 0x50: self = .save
        case 0x51: self = .undo
        case 0x52: self = .cancel
        case 0x53: self = .enter
        case 0x54: self = .marker
        case 0x55: self = .nudge
        case 0x56: self = .cycle
        case 0x57: self = .drop
        case 0x58: self = .replace
        case 0x59: self = .click
        case 0x5A: self = .globalSolo
        case 0x5B: self = .rewind
        case 0x5C: self = .fastForward
        case 0x5D: self = .stop
        case 0x5E: self = .play
        case 0x5F: self = .record
        case 0x60: self = .cursorUp
        case 0x61: self = .cursorDown
        case 0x62: self = .cursorLeft
        case 0x63: self = .cursorRight
        case 0x64: self = .zoom
        case 0x65: self = .scrub
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Implement `MCUCodec`**

`Sources/LogicMCPCore/MCU/MCUCodec.swift`:

```swift
public enum LEDState: Equatable, Sendable { case off, on, blink }

public enum MCUCommand: Equatable, Sendable {
    case faderMove(channel: Int, value: Int)      // value 0...16383
    case faderTouch(channel: Int, touched: Bool)
    case buttonPress(MCUButton)
    case buttonRelease(MCUButton)
    case vpotTurn(channel: Int, ticks: Int)       // ticks -7...-1, 1...7
    case hostConnectionQuery(serial: [UInt8], challenge: [UInt8])
    case connectionConfirmation(serial: [UInt8])
}

public enum MCUEvent: Equatable, Sendable {
    case faderEcho(channel: Int, value: Int)
    case lcd(offset: Int, text: String)
    case led(button: MCUButton, state: LEDState)
    case vpotRing(channel: Int, value: Int)
    case timecodeDigit(index: Int, char: Character)
    case meter(channel: Int, level: Int)
    case deviceQuery
    case hostConnectionReply(serial: [UInt8])
}

public enum MCUCodec {
    static let sysExHeader: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14]

    // MARK: surface → Logic

    public static func encode(_ command: MCUCommand) -> [UInt8] {
        switch command {
        case .faderMove(let ch, let v):
            let clamped = max(0, min(16383, v))
            return [0xE0 | UInt8(ch), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)]
        case .faderTouch(let ch, let touched):
            let note: UInt8 = ch == 8 ? 0x70 : 0x68 + UInt8(ch)
            return [0x90, note, touched ? 0x7F : 0x00]
        case .buttonPress(let b):
            return [0x90, b.note, 0x7F]
        case .buttonRelease(let b):
            return [0x90, b.note, 0x00]
        case .vpotTurn(let ch, let ticks):
            let magnitude = UInt8(min(7, abs(ticks)))
            let value = ticks >= 0 ? magnitude : 0x40 | magnitude
            return [0xB0, 0x10 + UInt8(ch), value]
        case .hostConnectionQuery(let serial, let challenge):
            return sysExHeader + [0x01] + serial + challenge + [0xF7]
        case .connectionConfirmation(let serial):
            return sysExHeader + [0x03] + serial + [0xF7]
        }
    }

    // MARK: Logic → surface (used by FakeLogic and the capture tool)

    public static func encode(_ event: MCUEvent) -> [UInt8] {
        switch event {
        case .faderEcho(let ch, let v):
            let clamped = max(0, min(16383, v))
            return [0xE0 | UInt8(ch), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)]
        case .lcd(let offset, let text):
            return sysExHeader + [0x12, UInt8(offset)] + Array(text.utf8) + [0xF7]
        case .led(let button, let state):
            let velocity: UInt8 = switch state { case .off: 0x00; case .blink: 0x01; case .on: 0x7F }
            return [0x90, button.note, velocity]
        case .vpotRing(let ch, let v):
            return [0xB0, 0x30 + UInt8(ch), UInt8(v & 0x7F)]
        case .timecodeDigit(let index, let char):
            let ascii = char.asciiValue ?? 0x20
            let code: UInt8 = ascii >= 0x40 ? ascii - 0x40 : ascii
            return [0xB0, 0x40 + UInt8(index), code & 0x3F]
        case .meter(let ch, let level):
            return [0xD0, UInt8((ch << 4) | (level & 0x0F))]
        case .deviceQuery:
            return sysExHeader + [0x00, 0xF7]
        case .hostConnectionReply(let serial):
            return sysExHeader + [0x02] + serial + [0xF7]
        }
    }

    // MARK: decoding

    public static func decodeEvent(_ bytes: [UInt8]) -> MCUEvent? {
        guard let first = bytes.first else { return nil }
        switch first & 0xF0 {
        case 0xE0:
            guard bytes.count == 3 else { return nil }
            return .faderEcho(channel: Int(first & 0x0F), value: Int(bytes[2]) << 7 | Int(bytes[1]))
        case 0x90:
            guard bytes.count == 3, let button = MCUButton(note: bytes[1]) else { return nil }
            let state: LEDState = bytes[2] == 0x00 ? .off : (bytes[2] == 0x7F ? .on : .blink)
            return .led(button: button, state: state)
        case 0xB0:
            guard bytes.count == 3 else { return nil }
            switch bytes[1] {
            case 0x30...0x37:
                return .vpotRing(channel: Int(bytes[1]) - 0x30, value: Int(bytes[2]))
            case 0x40...0x49:
                let low6 = bytes[2] & 0x3F
                let ascii = low6 < 0x20 ? low6 + 0x40 : low6
                return .timecodeDigit(index: Int(bytes[1]) - 0x40,
                                      char: Character(UnicodeScalar(ascii)))
            default:
                return nil
            }
        case 0xD0:
            guard bytes.count == 2 else { return nil }
            return .meter(channel: Int(bytes[1] >> 4), level: Int(bytes[1] & 0x0F))
        case 0xF0:
            guard bytes.count >= 7, Array(bytes.prefix(5)) == sysExHeader, bytes.last == 0xF7 else { return nil }
            let body = Array(bytes[5..<(bytes.count - 1)])
            switch body.first {
            case 0x00:
                return .deviceQuery
            case 0x02:
                return .hostConnectionReply(serial: Array(body.dropFirst().prefix(7)))
            case 0x12:
                guard body.count >= 2 else { return nil }
                let text = String(bytes: body.dropFirst(2), encoding: .ascii) ?? ""
                return .lcd(offset: Int(body[1]), text: text)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    public static func decodeCommand(_ bytes: [UInt8]) -> MCUCommand? {
        guard let first = bytes.first else { return nil }
        switch first & 0xF0 {
        case 0xE0:
            guard bytes.count == 3 else { return nil }
            return .faderMove(channel: Int(first & 0x0F), value: Int(bytes[2]) << 7 | Int(bytes[1]))
        case 0x90:
            guard bytes.count == 3 else { return nil }
            if (0x68...0x70).contains(bytes[1]) {
                let ch = bytes[1] == 0x70 ? 8 : Int(bytes[1]) - 0x68
                return .faderTouch(channel: ch, touched: bytes[2] != 0)
            }
            guard let button = MCUButton(note: bytes[1]) else { return nil }
            return bytes[2] == 0 ? .buttonRelease(button) : .buttonPress(button)
        case 0xB0:
            guard bytes.count == 3, (0x10...0x17).contains(bytes[1]) else { return nil }
            let magnitude = Int(bytes[2] & 0x07)
            let ticks = (bytes[2] & 0x40) != 0 ? -magnitude : magnitude
            return .vpotTurn(channel: Int(bytes[1]) - 0x10, ticks: ticks)
        case 0xF0:
            guard bytes.count >= 7, Array(bytes.prefix(5)) == sysExHeader, bytes.last == 0xF7 else { return nil }
            let body = Array(bytes[5..<(bytes.count - 1)])
            switch body.first {
            case 0x01:
                let payload = Array(body.dropFirst())
                return .hostConnectionQuery(serial: Array(payload.prefix(7)),
                                            challenge: Array(payload.dropFirst(7).prefix(4)))
            case 0x03:
                return .connectionConfirmation(serial: Array(body.dropFirst().prefix(7)))
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MCUCodecTests 2>&1 | tail -5`
Expected: PASS, 9 tests.

- [ ] **Step 6: Stop — task complete, do not commit.**

---

### Task 3: Fader curve (raw position ⇄ dB)

**Files:**
- Create: `Sources/LogicMCPCore/MCU/FaderCurve.swift`
- Test: `Tests/LogicMCPCoreTests/FaderCurveTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum FaderCurve { static func dB(fromRaw: Int) -> Double?  /* nil = -∞ */; static func raw(fromDB: Double) -> Int }`.

**Calibration note:** the anchor table below is the v0 curve — plausible shape, correct endpoints (raw 0 = −∞, raw 16383 = +6.0 dB, Logic's fader range). Absolute accuracy is refined in Task 16 by capturing a real fader sweep and updating the anchors; every consumer goes through this one type, and echo-verification means returned values stay self-consistent either way.

- [ ] **Step 1: Write the failing tests**

`Tests/LogicMCPCoreTests/FaderCurveTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class FaderCurveTests: XCTestCase {
    func testEndpoints() {
        XCTAssertNil(FaderCurve.dB(fromRaw: 0))                       // -∞
        XCTAssertEqual(FaderCurve.dB(fromRaw: 16383)!, 6.0, accuracy: 0.01)
        XCTAssertEqual(FaderCurve.raw(fromDB: 6.0), 16383)
        XCTAssertEqual(FaderCurve.raw(fromDB: -200), 0)               // clamps to -∞
    }

    func testUnityAnchor() {
        XCTAssertEqual(FaderCurve.dB(fromRaw: 12288)!, 0.0, accuracy: 0.01)
        XCTAssertEqual(FaderCurve.raw(fromDB: 0.0), 12288)
    }

    func testMonotonic() {
        var previous = -Double.infinity
        for raw in stride(from: 1, through: 16383, by: 128) {
            let db = FaderCurve.dB(fromRaw: raw)!
            XCTAssertGreaterThan(db, previous, "curve must be strictly increasing at raw \(raw)")
            previous = db
        }
    }

    func testRoundTripWithinOneRawStep() {
        for raw in stride(from: 64, through: 16383, by: 517) {
            let db = FaderCurve.dB(fromRaw: raw)!
            XCTAssertEqual(FaderCurve.raw(fromDB: db), raw, accuracy: 2)
        }
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FaderCurveTests 2>&1 | tail -5`
Expected: compile failure — `FaderCurve` doesn't exist.

- [ ] **Step 3: Implement**

`Sources/LogicMCPCore/MCU/FaderCurve.swift`:

```swift
/// Maps the MCU fader's 14-bit position to Logic's dB scale (-∞ … +6 dB).
/// v0 anchors; recalibrated from a captured fader sweep in Task 16.
public enum FaderCurve {
    // (raw, dB) — strictly increasing in both columns. raw 0 is -∞ (returned as nil).
    static let anchors: [(raw: Int, db: Double)] = [
        (1, -96.0),
        (256, -72.0),
        (1024, -54.0),
        (2560, -42.0),
        (4096, -30.0),
        (6144, -21.0),
        (8192, -12.0),
        (10240, -6.0),
        (12288, 0.0),
        (14336, 3.0),
        (16383, 6.0),
    ]

    public static func dB(fromRaw raw: Int) -> Double? {
        if raw <= 0 { return nil }
        let clamped = min(raw, 16383)
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if clamped <= upper.raw {
                let t = Double(clamped - lower.raw) / Double(upper.raw - lower.raw)
                let db = lower.db + t * (upper.db - lower.db)
                return (db * 10).rounded() / 10
            }
            lower = upper
        }
        return 6.0
    }

    public static func raw(fromDB db: Double) -> Int {
        if db <= anchors[0].db { return 0 }
        if db >= 6.0 { return 16383 }
        var lower = anchors[0]
        for upper in anchors.dropFirst() {
            if db <= upper.db {
                let t = (db - lower.db) / (upper.db - lower.db)
                return lower.raw + Int((t * Double(upper.raw - lower.raw)).rounded())
            }
            lower = upper
        }
        return 16383
    }
}
```

Note the rounding to 0.1 dB in `dB(fromRaw:)` — tool output reports one decimal, matching Logic's own display granularity. If `testRoundTripWithinOneRawStep` fails from that rounding, raise the test's `accuracy` to the raw-step equivalent of 0.05 dB at that anchor spacing (≈ 20 raw steps) rather than removing the rounding.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FaderCurveTests 2>&1 | tail -5`
Expected: PASS, 4 tests.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 4: Wire abstraction + transcript infrastructure

**Files:**
- Create: `Sources/LogicMCPCore/MCU/MCUWire.swift`
- Create: `Sources/LogicMCPCore/Support/Transcript.swift`
- Test: `Tests/LogicMCPCoreTests/TranscriptTests.swift`
- Create: `Tests/LogicMCPCoreTests/Fixtures/handshake.jsonl`

**Interfaces:**
- Consumes: `MCUCodec` (Task 2).
- Produces:
  - `protocol MCUWire: Sendable { func send(_ bytes: [UInt8]) async; func packets() -> AsyncStream<[UInt8]> }` — one MIDI message per `[UInt8]` packet.
  - `final class InMemoryWire: MCUWire` and `InMemoryWire.pair() -> (daemonEnd: InMemoryWire, logicEnd: InMemoryWire)` — what one end sends, the other receives. `FakeLogic` (Task 5) sits on `logicEnd`.
  - `struct TranscriptEntry: Codable { var dir: String /* "in" = Logic→daemon, "out" = daemon→Logic */; var hex: String }`, `enum Transcript { static func load(_ url: URL) throws -> [TranscriptEntry]; static func write(_ entries: [TranscriptEntry], to url: URL) throws; static func bytes(_ entry: TranscriptEntry) -> [UInt8] }`.
  - `final class ScriptedWire: MCUWire` — replays a transcript's `in` entries to the daemon and records everything the daemon sends; `init(transcript: [TranscriptEntry])`, `var sent: [[UInt8]] { get async }`, `func playNext(count: Int) async` (feeds the next *n* `in` entries; entries with dir `out` are assertions available via `expectedOut`).

**Transcript format** (JSONL, one message per line — hand-writable and producible by the Task 16 capture tool):

```
{"dir":"in","hex":"F0 00 00 66 14 00 F7"}
{"dir":"out","hex":"F0 00 00 66 14 01 4C 4D 43 50 30 30 31 01 02 03 04 F7"}
```

- [ ] **Step 1: Write the failing tests**

`Tests/LogicMCPCoreTests/TranscriptTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class TranscriptTests: XCTestCase {
    func testLoadFixtureAndHexParse() throws {
        let url = Bundle.module.url(forResource: "handshake", withExtension: "jsonl",
                                    subdirectory: "Fixtures")!
        let entries = try Transcript.load(url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].dir, "in")
        XCTAssertEqual(Transcript.bytes(entries[0]), [0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7])
    }

    func testInMemoryWirePairIsCrossConnected() async {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let stream = logicEnd.packets()
        await daemonEnd.send([0x90, 0x5E, 0x7F])
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, [0x90, 0x5E, 0x7F])
    }

    func testScriptedWireReplaysInEntriesAndRecordsSent() async throws {
        let transcript = [
            TranscriptEntry(dir: "in", hex: "E0 00 40"),
            TranscriptEntry(dir: "in", hex: "90 5E 7F"),
        ]
        let wire = ScriptedWire(transcript: transcript)
        let stream = wire.packets()
        await wire.playNext(count: 2)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [0xE0, 0x00, 0x40])
        await wire.send([0x90, 0x5D, 0x7F])
        let sent = await wire.sent
        XCTAssertEqual(sent, [[0x90, 0x5D, 0x7F]])
    }
}
```

`Tests/LogicMCPCoreTests/Fixtures/handshake.jsonl` (exactly two lines):

```
{"dir":"in","hex":"F0 00 00 66 14 00 F7"}
{"dir":"out","hex":"F0 00 00 66 14 01 4C 4D 43 50 30 30 31 01 02 03 04 F7"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriptTests 2>&1 | tail -5`
Expected: compile failure.

- [ ] **Step 3: Implement the wire**

`Sources/LogicMCPCore/MCU/MCUWire.swift`:

```swift
public protocol MCUWire: Sendable {
    func send(_ bytes: [UInt8]) async
    func packets() -> AsyncStream<[UInt8]>
}

/// In-process wire; `pair()` cross-connects two ends.
public final class InMemoryWire: MCUWire, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]
    private var peer: InMemoryWire?

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
        for continuation in continuations.values { continuation.yield(bytes) }
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
}
```

`import Foundation` at the top (for `NSLock`, `UUID`).

- [ ] **Step 4: Implement transcripts + ScriptedWire**

`Sources/LogicMCPCore/Support/Transcript.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TranscriptTests 2>&1 | tail -5`
Expected: PASS, 3 tests. If `testScriptedWireReplaysInEntriesAndRecordsSent` races (playNext before the stream registered), add `try await Task.sleep(for: .milliseconds(20))` after creating the stream — acceptable in this test-only path.

- [ ] **Step 6: Stop — task complete, do not commit.**

---

### Task 5: FakeLogic simulator

The test double for everything downstream: an actor on the `logicEnd` of an `InMemoryWire` pair that behaves like Logic's MCU host — echoes fader moves, toggles mute/solo LEDs, banks the LCD, runs a fake transport, serves send and plugin-parameter pages.

**Files:**
- Create: `Tests/LogicMCPCoreTests/FakeLogic.swift`
- Test: `Tests/LogicMCPCoreTests/FakeLogicTests.swift`

**Interfaces:**
- Consumes: `MCUCodec`, `MCUButton`, `InMemoryWire` (Tasks 2, 4).
- Produces (test target only):

```swift
actor FakeLogic {
    struct FakeTrack {
        var name: String                  // full name; LCD cells show the 7-char truncation
        var volumeRaw: Int = 12288        // 0 dB
        var pan: Int = 64                 // 0-127, 64 = center
        var mute = false
        var solo = false
        var sends: [(bus: String, level: Int)] = []   // level 0-127
        var plugins: [FakePlugin] = []
    }
    struct FakePlugin {
        var name: String
        var params: [(name: String, value: Double)]   // display derives as "%.2f"
    }
    init(wire: InMemoryWire, tracks: [FakeTrack])
    static func standardSession() -> [FakeTrack]   // 16 tracks: Kick, Snare, HiHat, Toms, OH, Room, Bass, Guitar L, Guitar R, Keys, Vocal, Vocal Dbl, BGV, FX Ret, Drum Bus, Mix Bus
    func start()
    var state: [FakeTrack] { get }
    var isPlaying: Bool { get }
    var bankOffset: Int { get }
}
```

**Behavioral contract** (each bullet becomes logic in `handle(_ command: MCUCommand)`):
- `faderMove(ch, v)` while that channel's fader was touched → update `tracks[bankOffset+ch].volumeRaw`, reply with identical `.faderEcho`. Moves without touch are still honored (Logic accepts them), still echoed.
- `buttonPress(.mute(ch))` → toggle mute on `bankOffset+ch`, reply `.led(.mute(ch), state:)`. Same for `.solo`, `.recArm`, `.select` (select is exclusive: LED off for previous selection).
- `buttonPress(.bankRight)` → banks move in stride-8 windows; the last bank starts at the stride-aligned `((trackCount-1)/8)*8`, so channels past the final track show blank cells: `bankOffset = min(bankOffset+8, max(0, ((trackCount-1)/8)*8))`; `.bankLeft` → `max(0, bankOffset-8)`; then re-send the full LCD top line: 8 cells of 7 chars, each `track.name.prefix(7)` padded to 7 with trailing spaces (blank channels are 7 spaces). If the bank didn't move (already at the edge), send nothing — the daemon detects the end of the mixer by LCD silence.
- `buttonPress(.play)` → `isPlaying = true`, reply `.led(.play, .on)` and `.led(.stop, .off)`; `.stop` → inverse. `.record` with `isPlaying` → `isRecording = true`, `.led(.record, .on)`. `.cycle` → toggle `cycling`, `.led(.cycle, on/off)`.
- `vpotTurn(ch, ticks)` in pan assignment → `pan = clamp(pan + ticks, 0, 127)`, reply `.vpotRing(ch, value: 1 + pan / 12)`.
- `buttonPress(.assignSend)` → send mode: LCD top = send destination names for the *selected* track (7-char cells, one send per channel cell), LCD bottom = integer levels rendered as 7-char cells; `vpotTurn(ch, ticks)` edits the level of send *ch* and resends both LCD lines.
- `buttonPress(.assignPlugin)` → plugin-select mode: LCD top = plugin names on the selected track (one per cell); `vpotPress(ch)` enters plugin-edit for plugin *ch*: LCD top = first 8 param names (7-char), bottom = values as `String(format: "%.2f", value)`; `vpotTurn(ch, ticks)` → `params[page*8+ch].value += ticks * 0.05` (clamped 0…1) and resends the page; `.channelRight`/`.channelLeft` page params by 8.
- `buttonPress(.automationRead/.write/.touch/.latch)` → set the selected track's automation mode, echo `.led` for the pressed button on, others off.
- `.deviceQuery` is answered by the daemon, not FakeLogic; FakeLogic *sends* `.deviceQuery` once on `start()` and, upon receiving `.hostConnectionQuery`, replies `.hostConnectionReply(serial:)` then expects `.connectionConfirmation` — after which it sends the initial LCD (bank 0 names) and transport LEDs.

- [ ] **Step 1: Write the failing tests** — `Tests/LogicMCPCoreTests/FakeLogicTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class FakeLogicTests: XCTestCase {
    private func makePair() async -> (daemon: InMemoryWire, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        return (daemonEnd, fake)
    }

    /// Collect events from the daemon end until `predicate` matches or timeout.
    private func awaitEvent(_ wire: InMemoryWire, timeout: Duration = .seconds(1),
                            where predicate: @escaping (MCUEvent) -> Bool) async -> MCUEvent? {
        let stream = wire.packets()
        return await withTaskGroup(of: MCUEvent?.self) { group in
            group.addTask {
                for await packet in stream {
                    if let event = MCUCodec.decodeEvent(packet), predicate(event) { return event }
                }
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

    func testFaderMoveIsEchoedAndStored() async {
        let (daemon, fake) = await makePair()
        async let echo = awaitEvent(daemon) {
            if case .faderEcho(0, 9000) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: true)))
        await daemon.send(MCUCodec.encode(MCUCommand.faderMove(channel: 0, value: 9000)))
        await daemon.send(MCUCodec.encode(MCUCommand.faderTouch(channel: 0, touched: false)))
        let received = await echo
        XCTAssertNotNil(received)
        let state = await fake.state
        XCTAssertEqual(state[0].volumeRaw, 9000)
    }

    func testMuteTogglesAndLEDEchoes() async {
        let (daemon, fake) = await makePair()
        async let led = awaitEvent(daemon) {
            if case .led(.mute(channel: 2), .on) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.mute(channel: 2))))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.mute(channel: 2))))
        XCTAssertNotNil(await led)
        let state = await fake.state
        XCTAssertTrue(state[2].mute)
    }

    func testBankRightShiftsLCDNames() async {
        let (daemon, fake) = await makePair()
        // Track 8 (0-based) in the standard session is "Guitar R" → LCD cell "Guitar "
        async let lcd = awaitEvent(daemon) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("Guitar ") } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.bankRight)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.bankRight)))
        XCTAssertNotNil(await lcd)
        let offset = await fake.bankOffset
        XCTAssertEqual(offset, 8)
    }

    func testPlayLightsPlayLED() async {
        let (daemon, fake) = await makePair()
        async let led = awaitEvent(daemon) {
            if case .led(.play, .on) = $0 { return true } else { return false }
        }
        await daemon.send(MCUCodec.encode(MCUCommand.buttonPress(.play)))
        await daemon.send(MCUCodec.encode(MCUCommand.buttonRelease(.play)))
        XCTAssertNotNil(await led)
        let playing = await fake.isPlaying
        XCTAssertTrue(playing)
    }

    func testHandshakeEndsWithInitialLCD() async {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        async let lcd = awaitEvent(daemonEnd, timeout: .seconds(2)) {
            if case .lcd(0, let text) = $0 { return text.hasPrefix("Kick") } else { return false }
        }
        async let query = awaitEvent(daemonEnd) {
            if case .deviceQuery = $0 { return true } else { return false }
        }
        await fake.start()
        XCTAssertNotNil(await query)
        // Complete the handshake the way MCUSession will (Task 7):
        await daemonEnd.send(MCUCodec.encode(MCUCommand.hostConnectionQuery(
            serial: Array("LMCP001".utf8), challenge: [1, 2, 3, 4])))
        XCTAssertNotNil(await lcd)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FakeLogicTests 2>&1 | tail -5`
Expected: compile failure — `FakeLogic` doesn't exist.

- [ ] **Step 3: Implement FakeLogic**

`Tests/LogicMCPCoreTests/FakeLogic.swift` — the skeleton below is complete for the behaviors tested above plus sends/plugins/automation (used by Tasks 12–14); implement all listed handlers now so later tasks only *use* it:

```swift
import Foundation
@testable import LogicMCPCore

actor FakeLogic {
    struct FakeTrack {
        var name: String
        var volumeRaw: Int = 12288
        var pan: Int = 64
        var mute = false
        var solo = false
        var recArm = false
        var automationMode = "read"
        var sends: [(bus: String, level: Int)] = []
        var plugins: [FakePlugin] = []
    }
    struct FakePlugin {
        var name: String
        var params: [(name: String, value: Double)]
    }

    private enum Assignment { case pan, send, pluginSelect, pluginEdit(slot: Int, page: Int) }

    private let wire: InMemoryWire
    private(set) var tracks: [FakeTrack]
    private(set) var bankOffset = 0
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private(set) var cycling = false
    private var selected = 0
    private var assignment: Assignment = .pan
    private var touched = Set<Int>()
    private var emitChain: Task<Void, Never>?

    var state: [FakeTrack] { tracks }

    init(wire: InMemoryWire, tracks: [FakeTrack]) {
        self.wire = wire
        self.tracks = tracks
    }

    static func standardSession() -> [FakeTrack] {
        let names = ["Kick", "Snare", "HiHat", "Toms", "OH", "Room", "Bass", "Guitar L",
                     "Guitar R", "Keys", "Vocal", "Vocal Dbl", "BGV", "FX Ret", "Drum Bus", "Mix Bus"]
        return names.map { name in
            var t = FakeTrack(name: name)
            t.sends = [("Bus 1", 0), ("Bus 2", 0)]
            t.plugins = [FakePlugin(name: "ChanEQ", params: [
                ("LowFrq", 0.2), ("LowGain", 0.5), ("MidFrq", 0.5), ("MidGain", 0.5),
                ("MidQ", 0.4), ("HiFrq", 0.7), ("HiGain", 0.5), ("Out", 0.8),
                ("HPFrq", 0.1), ("HPOn", 0.0),
            ])]
            return t
        }
    }

    func start() {
        let stream = wire.packets()
        Task { [weak self] in
            for await packet in stream {
                guard let self else { break }
                if let command = MCUCodec.decodeCommand(packet) {
                    await self.handle(command)
                }
            }
        }
        emit(.deviceQuery)
    }

    /// Emits are chained so events reach the daemon in the order Logic would send them.
    private func emit(_ event: MCUEvent) {
        let bytes = MCUCodec.encode(event)
        let previous = emitChain
        emitChain = Task { [wire] in
            await previous?.value
            await wire.send(bytes)
        }
    }

    private func handle(_ command: MCUCommand) {
        switch command {
        case .hostConnectionQuery(let serial, _):
            emit(.hostConnectionReply(serial: serial))
            sendBankLCD()
            emit(.led(button: .play, state: isPlaying ? .on : .off))
        case .connectionConfirmation:
            break
        case .faderTouch(let ch, let isTouched):
            if isTouched { touched.insert(ch) } else { touched.remove(ch) }
        case .faderMove(let ch, let value):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].volumeRaw = value
            emit(.faderEcho(channel: ch, value: value))
        case .buttonPress(let button):
            handlePress(button)
        case .buttonRelease:
            break
        case .vpotTurn(let ch, let ticks):
            handleVPot(channel: ch, ticks: ticks)
        }
    }

    private func handlePress(_ button: MCUButton) {
        switch button {
        case .mute(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].mute.toggle()
            emit(.led(button: .mute(channel: ch), state: tracks[index].mute ? .on : .off))
        case .solo(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].solo.toggle()
            emit(.led(button: .solo(channel: ch), state: tracks[index].solo ? .on : .off))
        case .recArm(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].recArm.toggle()
            emit(.led(button: .recArm(channel: ch), state: tracks[index].recArm ? .on : .off))
        case .select(let ch):
            let previous = selected - bankOffset
            if (0..<8).contains(previous) {
                emit(.led(button: .select(channel: previous), state: .off))
            }
            selected = bankOffset + ch
            emit(.led(button: .select(channel: ch), state: .on))
        case .bankRight:
            let lastBankStart = max(0, ((tracks.count - 1) / 8) * 8)
            let next = min(bankOffset + 8, lastBankStart)
            if next != bankOffset { bankOffset = next; sendBankLCD() }
        case .bankLeft:
            let next = max(0, bankOffset - 8)
            if next != bankOffset { bankOffset = next; sendBankLCD() }
        case .play:
            isPlaying = true
            emit(.led(button: .play, state: .on))
            emit(.led(button: .stop, state: .off))
        case .stop:
            isPlaying = false
            isRecording = false
            emit(.led(button: .stop, state: .on))
            emit(.led(button: .play, state: .off))
            emit(.led(button: .record, state: .off))
        case .record:
            isRecording = true
            if !isPlaying { isPlaying = true; emit(.led(button: .play, state: .on)) }
            emit(.led(button: .record, state: .on))
        case .cycle:
            cycling.toggle()
            emit(.led(button: .cycle, state: cycling ? .on : .off))
        case .assignPan:
            assignment = .pan
            sendBankLCD()
        case .assignSend:
            assignment = .send
            sendSendLCD()
        case .assignPlugin:
            assignment = .pluginSelect
            sendPluginSelectLCD()
        case .vpotPress(let ch):
            if case .pluginSelect = assignment, ch < tracks[selected].plugins.count {
                assignment = .pluginEdit(slot: ch, page: 0)
                sendPluginEditLCD()
            }
        case .channelRight:
            if case .pluginEdit(let slot, let page) = assignment {
                let paramCount = tracks[selected].plugins[slot].params.count
                if (page + 1) * 8 < paramCount {
                    assignment = .pluginEdit(slot: slot, page: page + 1)
                    sendPluginEditLCD()
                }
            }
        case .channelLeft:
            if case .pluginEdit(let slot, let page) = assignment, page > 0 {
                assignment = .pluginEdit(slot: slot, page: page - 1)
                sendPluginEditLCD()
            }
        case .automationRead, .automationWrite, .automationTouch, .automationLatch:
            let mode: String = switch button {
            case .automationWrite: "write"
            case .automationTouch: "touch"
            case .automationLatch: "latch"
            default: "read"
            }
            tracks[selected].automationMode = mode
            for b: MCUButton in [.automationRead, .automationWrite, .automationTouch, .automationLatch] {
                emit(.led(button: b, state: b == button ? .on : .off))
            }
        default:
            break
        }
    }

    private func handleVPot(channel: Int, ticks: Int) {
        switch assignment {
        case .pan:
            let index = bankOffset + channel
            guard index < tracks.count else { return }
            tracks[index].pan = max(0, min(127, tracks[index].pan + ticks))
            emit(.vpotRing(channel: channel, value: 1 + tracks[index].pan / 12))
        case .send:
            guard channel < tracks[selected].sends.count else { return }
            let level = max(0, min(127, tracks[selected].sends[channel].level + ticks))
            tracks[selected].sends[channel].level = level
            sendSendLCD()
        case .pluginEdit(let slot, let page):
            let paramIndex = page * 8 + channel
            guard paramIndex < tracks[selected].plugins[slot].params.count else { return }
            var value = tracks[selected].plugins[slot].params[paramIndex].value
            value = max(0, min(1, value + Double(ticks) * 0.05))
            tracks[selected].plugins[slot].params[paramIndex].value = value
            sendPluginEditLCD()
        case .pluginSelect:
            break
        }
    }

    private func cell(_ text: String) -> String {
        String(text.prefix(7)).padding(toLength: 7, withPad: " ", startingAt: 0)
    }

    private func sendBankLCD() {
        var top = ""
        for ch in 0..<8 {
            let index = bankOffset + ch
            top += index < tracks.count ? cell(tracks[index].name) : "       "
        }
        emit(.lcd(offset: 0, text: top))
    }

    private func sendSendLCD() {
        var top = "", bottom = ""
        for ch in 0..<8 {
            if ch < tracks[selected].sends.count {
                let send = tracks[selected].sends[ch]
                top += cell(send.bus)
                bottom += cell(String(send.level))
            } else {
                top += "       "; bottom += "       "
            }
        }
        emit(.lcd(offset: 0, text: top))
        emit(.lcd(offset: 56, text: bottom))
    }

    private func sendPluginSelectLCD() {
        var top = ""
        for ch in 0..<8 {
            top += ch < tracks[selected].plugins.count ? cell(tracks[selected].plugins[ch].name) : "       "
        }
        emit(.lcd(offset: 0, text: top))
    }

    private func sendPluginEditLCD() {
        guard case .pluginEdit(let slot, let page) = assignment else { return }
        let params = tracks[selected].plugins[slot].params
        var top = "", bottom = ""
        for ch in 0..<8 {
            let index = page * 8 + ch
            if index < params.count {
                top += cell(params[index].name)
                bottom += cell(String(format: "%.2f", params[index].value))
            } else {
                top += "       "; bottom += "       "
            }
        }
        emit(.lcd(offset: 0, text: top))
        emit(.lcd(offset: 56, text: bottom))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FakeLogicTests 2>&1 | tail -5`
Expected: PASS, 5 tests.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 6: CoreMIDI virtual ports

**Files:**
- Create: `Sources/LogicMCPCore/MCU/CoreMIDIWire.swift`
- Test: `Tests/LogicMCPCoreTests/CoreMIDIWireTests.swift`

**Interfaces:**
- Consumes: `MCUWire` (Task 4).
- Produces: `final class CoreMIDIWire: MCUWire { init(portName: String) throws }` — creates a virtual MIDI **source** named `portName` (daemon → Logic) and a virtual **destination** named `portName` (Logic → daemon). Logic's Control Surfaces setup points a Mackie Control's output at our destination and input at our source.

**Notes for the implementer:**
- Use the classic MIDI 1.0 packet APIs (`MIDISourceCreate`, `MIDIDestinationCreateWithBlock`, `MIDIReceived`) — Logic talks MIDI 1.0 to control surfaces and the MCU protocol is bytes, not UMP. These are marked deprecated in favor of the protocol-aware variants; that's acceptable and stable. Silence the warnings with `@available` guards only if the build treats warnings as errors (it doesn't by default).
- SysEx can arrive split across `MIDIPacket`s: accumulate bytes from `0xF0` until `0xF7` before yielding; non-SysEx status bytes yield one packet per complete message (2 or 3 bytes by status).
- No entitlements or user permissions are required for virtual MIDI ports.

- [ ] **Step 1: Write the failing test**

`Tests/LogicMCPCoreTests/CoreMIDIWireTests.swift`:

```swift
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

        var iterator = stream.makeAsyncIterator()
        let received = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        XCTAssertEqual(received, [0x90, 0x5E, 0x7F])
    }
}

private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
    return (name?.takeRetainedValue() as String?) ?? ""
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CoreMIDIWireTests 2>&1 | tail -5`
Expected: compile failure — `CoreMIDIWire` doesn't exist.

- [ ] **Step 3: Implement**

`Sources/LogicMCPCore/MCU/CoreMIDIWire.swift`:

```swift
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
        guard status == noErr else { throw CoreMIDIError.sourceCreate(status) }
        status = MIDIDestinationCreateWithBlock(client, portName as CFString, &destination) {
            [weak self] packetList, _ in
            self?.receive(packetList)
        }
        guard status == noErr else { throw CoreMIDIError.destinationCreate(status) }
    }

    public func tearDown() {
        MIDIEndpointDispose(source)
        MIDIEndpointDispose(destination)
        MIDIClientDispose(client)
    }

    public func send(_ bytes: [UInt8]) async {
        var builder = MIDIPacketList()
        var packet = MIDIPacketListInit(&builder)
        packet = MIDIPacketListAdd(&builder, 1024, packet, 0, bytes.count, bytes)
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
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let count = Int(packet.length)
            let data = withUnsafeBytes(of: packet.data) { raw in
                Array(raw.prefix(count).bindMemory(to: UInt8.self))
            }
            split(data)
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    /// Split a raw packet into complete MIDI messages; reassemble SysEx across packets.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CoreMIDIWireTests 2>&1 | tail -5`
Expected: PASS, 1 test. (Runs against the real MIDI server; works headless, no permissions.)

- [ ] **Step 5: Run the full suite** — `swift test 2>&1 | tail -3` — everything still green.

- [ ] **Step 6: Stop — task complete, do not commit.**

---

### Task 7: MCUSession state machine

**Files:**
- Create: `Sources/LogicMCPCore/MCU/MCUSession.swift`
- Test: `Tests/LogicMCPCoreTests/MCUSessionTests.swift`

**Interfaces:**
- Consumes: `MCUWire`, `MCUCodec`, `MCUButton`, `FakeLogic` (tests).
- Produces:

```swift
public struct SurfaceState: Sendable {
    public var lcdTop: String        // 56 chars
    public var lcdBottom: String     // 56 chars
    public var faderRaw: [Int]       // 9 entries (8 + master), -1 = unknown
    public var leds: [MCUButton: LEDState]
    public var connected: Bool
    public func lcdCell(line: Int, channel: Int) -> String   // 7-char cell
}

public actor MCUSession {
    public init(wire: MCUWire, serial: [UInt8] = Array("LMCP001".utf8))
    public func start()
    public var surface: SurfaceState { get }
    public func events() -> AsyncStream<MCUEvent>            // decoded, post-state-update
    public func press(_ button: MCUButton) async             // press + release
    public func moveFader(channel: Int, toRaw: Int, timeout: Duration) async throws -> Int
    public func turnVPot(channel: Int, ticks: Int) async
    public func waitFor(timeout: Duration, _ predicate: @escaping @Sendable (MCUEvent) -> Bool) async -> MCUEvent?
    public func settle(_ quiet: Duration) async               // wait until no event for `quiet`
}
```

Behavior:
- `start()` consumes `wire.packets()`, decodes with `MCUCodec.decodeEvent`, applies each event to `SurfaceState` (LCD writes overwrite the char range at `offset`; fader echoes update `faderRaw`; LEDs update the map), then re-broadcasts on `events()`.
- Handshake: on `.deviceQuery` → send `.hostConnectionQuery(serial:challenge: [1,2,3,4])`; on `.hostConnectionReply` → send `.connectionConfirmation(serial:)` and set `connected = true`. Also set `connected = true` on the first `.lcd` event (covers hosts that skip the handshake).
- `moveFader` sends touch-on → move → touch-off, then waits for a `.faderEcho` on that channel; returns the echoed raw value or throws `ToolFailure(error: "no fader echo", layer: "mcu", expected: "echo on channel N within timeout", observed: "silence")`.
- `press` sends press then release (10 ms apart is plenty; use `Task.sleep(for: .milliseconds(10))`).
- `waitFor` subscribes to `events()` with a deadline — the same task-group-with-timeout shape as `awaitEvent` in FakeLogicTests.
- `settle` loops `waitFor` with the quiet window as timeout until it returns nil — used after banking to know the LCD burst finished.

- [ ] **Step 1: Write the failing tests**

`Tests/LogicMCPCoreTests/MCUSessionTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class MCUSessionTests: XCTestCase {
    private func makeSession() async -> (session: MCUSession, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        return (session, fake)
    }

    func testHandshakeCompletesAndLCDArrives() async {
        let (session, _) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let surface = await session.surface
        XCTAssertTrue(surface.connected)
        XCTAssertEqual(surface.lcdCell(line: 0, channel: 0), "Kick   ")
        XCTAssertEqual(surface.lcdCell(line: 0, channel: 6), "Bass   ")
    }

    func testMoveFaderReturnsEcho() async throws {
        let (session, fake) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let echoed = try await session.moveFader(channel: 2, toRaw: 4096, timeout: .seconds(1))
        XCTAssertEqual(echoed, 4096)
        let state = await fake.state
        XCTAssertEqual(state[2].volumeRaw, 4096)
        let surface = await session.surface
        XCTAssertEqual(surface.faderRaw[2], 4096)
    }

    func testMoveFaderTimesOutAsToolFailure() async {
        // Dead wire: no FakeLogic on the other end.
        let (daemonEnd, _) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        do {
            _ = try await session.moveFader(channel: 0, toRaw: 100, timeout: .milliseconds(150))
            XCTFail("expected ToolFailure")
        } catch let failure as ToolFailure {
            XCTAssertEqual(failure.layer, "mcu")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testLEDStateTracked() async {
        let (session, _) = await makeSession()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        async let led = session.waitFor(timeout: .seconds(1)) {
            if case .led(.play, .on) = $0 { return true } else { return false }
        }
        await session.press(.play)
        XCTAssertNotNil(await led)
        let surface = await session.surface
        XCTAssertEqual(surface.leds[.play], .on)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCUSessionTests 2>&1 | tail -5`
Expected: compile failure.

- [ ] **Step 3: Implement**

`Sources/LogicMCPCore/MCU/MCUSession.swift`:

```swift
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
```

**Race to watch:** `moveFader` subscribes via `events()` *before* sending, so the echo can't be missed. Keep that ordering.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCUSessionTests 2>&1 | tail -5`
Expected: PASS, 4 tests.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 8: Shadow model v0 + MixerNavigator

**Files:**
- Create: `Sources/LogicMCPCore/Model/ProjectModel.swift`
- Create: `Sources/LogicMCPCore/Model/MixerNavigator.swift`
- Test: `Tests/LogicMCPCoreTests/ProjectModelTests.swift`

**Interfaces:**
- Consumes: `MCUSession`, `FaderCurve`, `SurfaceState`, `ToolFailure`.
- Produces:

```swift
public struct TrackState: Codable, Sendable {
    public var index: Int          // global mixer index, 0-based
    public var name: String        // LCD name, trailing spaces trimmed (≤7 chars in this phase)
    public var volumeRaw: Int?     // nil until observed
    public var volumeDB: Double?   // nil = unobserved OR -∞ (see volumeIsSilent)
    public var volumeIsSilent: Bool
    public var pan: Int?           // 0-127, 64 = center
    public var mute: Bool
    public var solo: Bool
}

public struct TransportState: Codable, Sendable {
    public var playing: Bool
    public var recording: Bool
    public var cycling: Bool
}

public actor ProjectModel {
    public init()
    public func replaceTracks(_ names: [String])
    public func track(named: String) throws -> TrackState        // throws ToolFailure on miss/ambiguity
    public func updateTrack(index: Int, _ mutate: (inout TrackState) -> Void)
    public func setTransport(_ mutate: (inout TransportState) -> Void)
    public var snapshot: (tracks: [TrackState], transport: TransportState, staleAt: Date?) { get }
    public func markStale()
}

public actor MixerNavigator {
    public init(session: MCUSession, model: ProjectModel)
    public func enumerateTracks() async throws -> [String]        // banks through the whole mixer, resets to bank 0, fills the model
    public func bank(toShow globalIndex: Int) async throws -> Int // returns local channel 0-7 for that track
    public func resolve(_ name: String) async throws -> TrackState
}
```

**Name resolution rule** (`ProjectModel.track(named:)` and `MixerNavigator.resolve`): case-insensitive exact match on the trimmed LCD name first; if none, unique case-insensitive prefix match (handles "Vocal Dbl" → LCD "Vocal D"); zero matches → `ToolFailure(error: "no track named …", layer: "model", observed: "<comma-separated known names>")`; multiple matches → `ToolFailure(error: "ambiguous track name …", …)` listing candidates. Full-name reconciliation against the AX tree replaces this in Phase 3 (per spec "MCU LCD truncation" risk).

**Enumeration algorithm** (`enumerateTracks`): press `.bankLeft` until LCD stops changing (`settle(.milliseconds(150))` after each press; compare `surface.lcdTop` before/after) to reach bank 0 → read 8 cells → press `.bankRight`, settle; if `lcdTop` unchanged, the mixer ended; else append new non-blank cells and repeat (guard: stop after 32 banks = 256 tracks). Blank cells (7 spaces) inside a bank mean fewer than 8 tracks remain. Afterwards bank all the way left again, call `model.replaceTracks(names)`, return names. Track the model's `bankOffset` in the navigator as banks move — `bank(toShow:)` = press `.bankLeft`/`.bankRight` the computed number of times, settle after each, return `globalIndex - bankOffset`.

- [ ] **Step 1: Write the failing tests**

`Tests/LogicMCPCoreTests/ProjectModelTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class ProjectModelTests: XCTestCase {
    private func makeStack() async -> (session: MCUSession, model: ProjectModel, nav: MixerNavigator, fake: FakeLogic) {
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let model = ProjectModel()
        let nav = MixerNavigator(session: session, model: model)
        return (session, model, nav, fake)
    }

    func testEnumerateFindsAllSixteenTracks() async throws {
        let (_, _, nav, _) = await makeStack()
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 16)
        XCTAssertEqual(names.first, "Kick")
        XCTAssertEqual(names[8], "Guitar")   // "Guitar R" truncated to LCD cell "Guitar "
    }

    func testResolveExactAndPrefix() async throws {
        let (_, _, nav, _) = await makeStack()
        _ = try await nav.enumerateTracks()
        let vocal = try await nav.resolve("Vocal")
        XCTAssertEqual(vocal.index, 10)      // exact match wins over "Vocal D"
        let bgv = try await nav.resolve("bg") // unique prefix, case-insensitive
        XCTAssertEqual(bgv.index, 12)
    }

    func testResolveErrors() async throws {
        let (_, _, nav, _) = await makeStack()
        _ = try await nav.enumerateTracks()
        do {
            _ = try await nav.resolve("Trombone")
            XCTFail("expected miss")
        } catch let failure as ToolFailure {
            XCTAssertTrue(failure.error.contains("no track"))
            XCTAssertTrue(failure.observed?.contains("Kick") ?? false)
        }
        do {
            _ = try await nav.resolve("Guitar")   // "Guitar" cell appears twice (L and R truncate identically)
            XCTFail("expected ambiguity")
        } catch let failure as ToolFailure {
            XCTAssertTrue(failure.error.contains("ambiguous"))
        }
    }

    func testBankToShowReturnsLocalChannel() async throws {
        let (_, _, nav, fake) = await makeStack()
        _ = try await nav.enumerateTracks()
        let channel = try await nav.bank(toShow: 10)   // "Vocal"
        let offset = await fake.bankOffset
        XCTAssertEqual(offset + channel, 10)
        XCTAssertTrue((0..<8).contains(channel))
    }

    func testEnumerateTwelveTracksSkipsBlankCells() async throws {
        // Non-multiple-of-8: the last bank pads with 4 blank cells.
        let (daemonEnd, logicEnd) = InMemoryWire.pair()
        let session = MCUSession(wire: daemonEnd)
        await session.start()
        let twelve = Array(FakeLogic.standardSession().prefix(12))
        let fake = FakeLogic(wire: logicEnd, tracks: twelve)
        await fake.start()
        _ = await session.waitFor(timeout: .seconds(2)) {
            if case .lcd = $0 { return true } else { return false }
        }
        let nav = MixerNavigator(session: session, model: ProjectModel())
        let names = try await nav.enumerateTracks()
        XCTAssertEqual(names.count, 12)
        XCTAssertEqual(names.last, "Vocal D")   // "Vocal Dbl" truncated to the 7-char cell
    }
}
```

Note `testEnumerateFindsAllSixteenTracks` asserts `names[8] == "Guitar"`: "Guitar L" and "Guitar R" both truncate to the 7-char cell `"Guitar "` — by design, so the ambiguity path is honest to the spec's truncation risk (resolved properly by AX full names in Phase 3).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectModelTests 2>&1 | tail -5`
Expected: compile failure.

- [ ] **Step 3: Implement the model**

`Sources/LogicMCPCore/Model/ProjectModel.swift`:

```swift
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
```

- [ ] **Step 4: Implement the navigator**

`Sources/LogicMCPCore/Model/MixerNavigator.swift`:

```swift
import Foundation

public actor MixerNavigator {
    private let session: MCUSession
    private let model: ProjectModel
    private(set) var bankOffset = 0
    private let settleWindow = Duration.milliseconds(150)

    public init(session: MCUSession, model: ProjectModel) {
        self.session = session
        self.model = model
    }

    private func lcdTop() async -> String {
        await session.surface.lcdTop
    }

    private func pressAndSettle(_ button: MCUButton) async -> Bool {
        let before = await lcdTop()
        await session.press(button)
        await session.settle(settleWindow)
        return await lcdTop() != before
    }

    private func bankFullyLeft() async {
        while await pressAndSettle(.bankLeft) {}
        bankOffset = 0
    }

    private func currentBankNames() async -> [String] {
        let surface = await session.surface
        return (0..<8).map { surface.lcdCell(line: 0, channel: $0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func enumerateTracks() async throws -> [String] {
        await bankFullyLeft()
        var names = await currentBankNames().filter { !$0.isEmpty }
        guard !names.isEmpty else {
            throw ToolFailure(error: "mixer LCD is empty", layer: "mcu",
                              expected: "track names on the LCD",
                              observed: "blank display — is Logic running with the control surface installed?")
        }
        var banks = 1
        while banks < 32, await pressAndSettle(.bankRight) {
            bankOffset += 8
            banks += 1
            // Banks move in stride-8 windows; the last bank pads with blank cells,
            // so appending the non-blank cells of each new bank covers every track.
            names += await currentBankNames().filter { !$0.isEmpty }
        }
        await bankFullyLeft()
        await model.replaceTracks(names)
        return names
    }

    public func bank(toShow globalIndex: Int) async throws -> Int {
        while globalIndex >= bankOffset + 8 {
            guard await pressAndSettle(.bankRight) else {
                throw ToolFailure(error: "cannot bank to track \(globalIndex)", layer: "mcu",
                                  expected: "bank window containing index \(globalIndex)",
                                  observed: "mixer ends at offset \(bankOffset)")
            }
            bankOffset += 8
        }
        while globalIndex < bankOffset {
            guard await pressAndSettle(.bankLeft) else { break }
            bankOffset = max(0, bankOffset - 8)
        }
        return globalIndex - bankOffset
    }

    public func resolve(_ name: String) async throws -> TrackState {
        if await model.snapshot.staleAt != nil {
            _ = try await enumerateTracks()
        }
        return try await model.track(named: name)
    }
}
```

**Stride assumption, verified at Task 16:** FakeLogic models Logic's banking as stride-8 windows whose last bank is stride-aligned (blank cells past the final track). If the Task 16 captured transcripts show real Logic instead clamping the last bank to end exactly at the final track (overlapping the previous window), fix it there: update FakeLogic to match the transcript and change this append to dedupe by window alignment. The navigator's tests pin today's assumption so the divergence will be loud, not silent.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProjectModelTests 2>&1 | tail -5`
Expected: PASS, 4 tests.

- [ ] **Step 6: Stop — task complete, do not commit.**

---

### Task 9: Daemon assembly + query tools

Bundle the session/model/navigator into one `Daemon` context, then expose `get_project_overview`, `get_track`, `refresh_state`.

**Files:**
- Create: `Sources/LogicMCPCore/Daemon.swift`
- Create: `Sources/LogicMCPCore/Tools/QueryTools.swift`
- Modify: `Sources/logic-mcp/Main.swift` (wire Daemon + tools into `Serve`)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces:

```swift
public final class Daemon: Sendable {
    public let session: MCUSession
    public let model: ProjectModel
    public let navigator: MixerNavigator
    public let journal: UndoJournal      // added Task 15; until then omit this property
    public init(wire: MCUWire) async     // builds session/model/navigator, starts session
    public func registerAllTools(in registry: ToolRegistry) async  // grows as tool tasks land
}
```

- Tools produced: `get_project_overview()` → `{tracks: [{index, name, volumeDB, pan, mute, solo}], transport: {...}, stale: Bool}`; `get_track(name)` → one track object; `refresh_state(scope: "tracks")` → re-enumerates and returns the fresh overview.
- Test helper produced for all later tool tasks (add to `ToolTests.swift`):

```swift
func makeDaemonWithFakeLogic() async -> (daemon: Daemon, registry: ToolRegistry, fake: FakeLogic) {
    let (daemonEnd, logicEnd) = InMemoryWire.pair()
    let fake = FakeLogic(wire: logicEnd, tracks: FakeLogic.standardSession())
    let daemon = await Daemon(wire: daemonEnd)
    await fake.start()
    let registry = ToolRegistry()
    await daemon.registerAllTools(in: registry)
    _ = await daemon.session.waitFor(timeout: .seconds(2)) {
        if case .lcd = $0 { return true } else { return false }
    }
    return (daemon, registry, fake)
}

/// Decode a tool result's JSON text into a dictionary.
func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
    guard case .text(let json)? = result.content.first else { throw ToolFailure(error: "no text", layer: "daemon") }
    return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}
```

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testGetProjectOverviewListsTracks() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "get_project_overview", arguments: [:])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    let tracks = json["tracks"] as! [[String: Any]]
    XCTAssertEqual(tracks.count, 16)
    XCTAssertEqual(tracks[0]["name"] as? String, "Kick")
}

func testGetTrackByName() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
    let result = await registry.call(name: "get_track", arguments: ["name": .string("Vocal")])
    let json = try resultJSON(result)
    XCTAssertEqual(json["index"] as? Int, 10)
}

func testGetTrackMissIsStructuredError() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "refresh_state", arguments: ["scope": .string("tracks")])
    let result = await registry.call(name: "get_track", arguments: ["name": .string("Trombone")])
    XCTAssertEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["layer"] as? String, "model")
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ToolTests 2>&1 | tail -5` — compile failure.

- [ ] **Step 3: Implement `Daemon` and the query tools**

`Sources/LogicMCPCore/Daemon.swift`:

```swift
public final class Daemon: Sendable {
    public let session: MCUSession
    public let model: ProjectModel
    public let navigator: MixerNavigator

    public init(wire: MCUWire) async {
        session = MCUSession(wire: wire)
        model = ProjectModel()
        navigator = MixerNavigator(session: session, model: model)
        await session.start()
    }

    public func registerAllTools(in registry: ToolRegistry) async {
        await registry.register(PingTool(version: "0.1.0"))
        await registry.register(GetProjectOverviewTool(daemon: self))
        await registry.register(GetTrackTool(daemon: self))
        await registry.register(RefreshStateTool(daemon: self))
        // Later tasks append transport/mix/send/plugin/undo tools here.
    }
}
```

`Sources/LogicMCPCore/Tools/QueryTools.swift`:

```swift
import Foundation
import MCP

func trackValue(_ t: TrackState) -> Value {
    .object([
        "index": .int(t.index),
        "name": .string(t.name),
        "volumeDB": t.volumeDB.map { Value.double($0) } ?? .null,
        "volumeIsSilent": .bool(t.volumeIsSilent),
        "pan": t.pan.map { Value.int($0) } ?? .null,
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
```

- [ ] **Step 4: Update `Serve.run()`** in `Sources/logic-mcp/Main.swift` — replace the registry block:

```swift
let wire = try CoreMIDIWire()
let daemon = await Daemon(wire: wire)
let registry = ToolRegistry()
await daemon.registerAllTools(in: registry)
```

(Remove the direct `PingTool` registration — `registerAllTools` covers it.)

- [ ] **Step 5: Run tests** — `swift test 2>&1 | tail -3` — full suite PASS.

- [ ] **Step 6: Stop — task complete, do not commit.**

---

### Task 10: Transport tools

**Files:**
- Create: `Sources/LogicMCPCore/Tools/TransportTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register new tools)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: `Daemon`, `MCUSession.press/waitFor`, `ProjectModel.setTransport`.
- Produces tools: `play()`, `stop()`, `record(confirm: Bool)`, `toggle_cycle()`. Each presses the transport button, waits for the corresponding LED echo (the verification), updates `TransportState`, returns `{playing, recording, cycling}`.

**Scope note:** the spec's `locate(bar)` and `set_cycle(start, end)` need either numeric-position entry (an AX/key-command flow) or jog-feedback loops tuned on real Logic; they move to the Phase 3 (AXDriver) plan where they are one key command each (`Go to Position…`, cycle-range fields). This phase ships `toggle_cycle` (MCU CYCLE button) as the spec's cycle primitive. Deviation is recorded in "Later phases" below.

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testPlayVerifiedByLED() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "play", arguments: [:])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["playing"] as? Bool, true)
    let playing = await fake.isPlaying
    XCTAssertTrue(playing)
}

func testRecordRefusesWithoutConfirm() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "record", arguments: [:])
    XCTAssertEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertTrue((json["error"] as! String).contains("confirm"))
    let recording = await fake.isRecording
    XCTAssertFalse(recording)
}

func testRecordWithConfirm() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "record", arguments: ["confirm": .bool(true)])
    XCTAssertNotEqual(result.isError, true)
    let recording = await fake.isRecording
    XCTAssertTrue(recording)
}

func testStopAfterPlay() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "play", arguments: [:])
    let result = await registry.call(name: "stop", arguments: [:])
    let json = try resultJSON(result)
    XCTAssertEqual(json["playing"] as? Bool, false)
    let playing = await fake.isPlaying
    XCTAssertFalse(playing)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ToolTests 2>&1 | tail -5`.

- [ ] **Step 3: Implement**

`Sources/LogicMCPCore/Tools/TransportTools.swift`:

```swift
import MCP

func transportValue(_ t: TransportState) -> Value {
    .object(["playing": .bool(t.playing), "recording": .bool(t.recording), "cycling": .bool(t.cycling)])
}

/// Press a transport button, verify via LED echo, update the model.
func pressTransport(_ daemon: Daemon, button: MCUButton, expectLED: MCUButton, expectState: LEDState,
                    mutate: @escaping @Sendable (inout TransportState) -> Void) async throws -> Value {
    async let led = daemon.session.waitFor(timeout: .seconds(1)) {
        if case .led(let b, let s) = $0 { return b == expectLED && s == expectState } else { return false }
    }
    await daemon.session.press(button)
    guard await led != nil else {
        throw ToolFailure(error: "transport button not confirmed", layer: "mcu",
                          expected: "LED \(expectLED) → \(expectState)", observed: "no LED echo within 1s")
    }
    await daemon.model.setTransport(mutate)
    return await transportValue(daemon.model.snapshot.transport)
}

let emptySchema: Value = .object(["type": .string("object"), "properties": .object([:])])

public struct PlayTool: LogicTool {
    public let name = "play"
    public let description = "Start playback. Verified by Logic's play-LED echo."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        try await pressTransport(daemon, button: .play, expectLED: .play, expectState: .on) {
            $0.playing = true
        }
    }
}

public struct StopTool: LogicTool {
    public let name = "stop"
    public let description = "Stop playback (and recording). Verified by the stop-LED echo."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        try await pressTransport(daemon, button: .stop, expectLED: .stop, expectState: .on) {
            $0.playing = false
            $0.recording = false
        }
    }
}

public struct ToggleCycleTool: LogicTool {
    public let name = "toggle_cycle"
    public let description = "Toggle cycle (loop) mode. Returns the new transport state."
    public let inputSchema = emptySchema
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let currentlyCycling = await daemon.model.snapshot.transport.cycling
        return try await pressTransport(daemon, button: .cycle, expectLED: .cycle,
                                        expectState: currentlyCycling ? .off : .on) {
            $0.cycling.toggle()
        }
    }
}

public struct RecordTool: LogicTool {
    public let name = "record"
    public let description = "Start recording. NEVER call this unless the user explicitly asked to record in their most recent request. Requires confirm: true."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["confirm": .object([
            "type": .string("boolean"),
            "description": .string("Must be true; asserts the user explicitly requested recording."),
        ])]),
        "required": .array([.string("confirm")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard args["confirm"]?.boolValue == true else {
            throw ToolFailure(error: "record requires confirm: true — only pass it when the user explicitly asked to record", layer: "daemon")
        }
        return try await pressTransport(daemon, button: .record, expectLED: .record, expectState: .on) {
            $0.recording = true
            $0.playing = true
        }
    }
}
```

Register in `Daemon.registerAllTools`:

```swift
await registry.register(PlayTool(daemon: self))
await registry.register(StopTool(daemon: self))
await registry.register(ToggleCycleTool(daemon: self))
await registry.register(RecordTool(daemon: self))
```

- [ ] **Step 4: Run tests** — `swift test --filter ToolTests 2>&1 | tail -5` — PASS (7 new + existing).

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 11: `set_volume`

The archetype mutating tool: resolve track → bank to it → act → verify echo → update model → return ground truth.

**Files:**
- Create: `Sources/LogicMCPCore/Tools/MixTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: `Daemon`, `MixerNavigator.resolve/bank(toShow:)`, `MCUSession.moveFader`, `FaderCurve`.
- Produces: tool `set_volume(track, db?|delta?)` returning `{track, volumeDB, volumeRaw}`; helper `func resolveAndBank(_ daemon: Daemon, track: String) async throws -> (track: TrackState, channel: Int)` reused by every later mix tool.

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testSetVolumeAbsolute() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_volume",
                                     arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["volumeDB"] as! Double, -6.0, accuracy: 0.2)
    let state = await fake.state
    XCTAssertEqual(state[10].volumeRaw, FaderCurve.raw(fromDB: -6.0))
}

func testSetVolumeDelta() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "set_volume",
                            arguments: ["track": .string("Bass"), "db": .double(-3.0)])
    let result = await registry.call(name: "set_volume",
                                     arguments: ["track": .string("Bass"), "delta": .double(-2.0)])
    let json = try resultJSON(result)
    XCTAssertEqual(json["volumeDB"] as! Double, -5.0, accuracy: 0.3)
}

func testSetVolumeRequiresExactlyOneOfDbOrDelta() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let neither = await registry.call(name: "set_volume", arguments: ["track": .string("Bass")])
    XCTAssertEqual(neither.isError, true)
    let both = await registry.call(name: "set_volume", arguments: [
        "track": .string("Bass"), "db": .double(0), "delta": .double(1),
    ])
    XCTAssertEqual(both.isError, true)
}

func testSetVolumeDeltaOnUnobservedTrackReadsFaderFirst() async throws {
    // Delta with no prior volume knowledge: tool must first observe the current
    // position (FakeLogic tracks start at 12288 = 0 dB) and land at -2.
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_volume",
                                     arguments: ["track": .string("Kick"), "delta": .double(-2.0)])
    let json = try resultJSON(result)
    XCTAssertEqual(json["volumeDB"] as! Double, -2.0, accuracy: 0.3)
}
```

**Design point encoded by the last test:** Logic reports fader positions when the surface banks to a channel (and FakeLogic must too — see Step 3a). Delta moves need a current position; the shadow model supplies it, and banking populates it.

- [ ] **Step 2: Run to verify failure** — `swift test --filter ToolTests 2>&1 | tail -5`.

- [ ] **Step 3a: Teach FakeLogic to announce fader positions on bank/LCD refresh** (real Logic does this so motorized faders track). In `FakeLogic.sendBankLCD()` add, after the `emit(.lcd(...))`:

```swift
for ch in 0..<8 {
    let index = bankOffset + ch
    if index < tracks.count {
        emit(.faderEcho(channel: ch, value: tracks[index].volumeRaw))
    }
}
```

And in `MixerNavigator`, wire fader echoes into the model — add to `pressAndSettle` after settling (and once at the end of `bankFullyLeft`):

```swift
private func syncFadersFromSurface() async {
    let surface = await session.surface
    for ch in 0..<8 {
        let raw = surface.faderRaw[ch]
        guard raw >= 0 else { continue }
        let index = bankOffset + ch
        await model.updateTrack(index: index) {
            $0.volumeRaw = raw
            $0.volumeDB = FaderCurve.dB(fromRaw: raw)
            $0.volumeIsSilent = raw == 0
        }
    }
}
```

Call `await syncFadersFromSurface()` at the end of `enumerateTracks()` and `bank(toShow:)`.

- [ ] **Step 3b: Implement the tool**

`Sources/LogicMCPCore/Tools/MixTools.swift`:

```swift
import MCP

/// Resolve a track by name and bank the MCU window to show it. Every mix tool starts here.
func resolveAndBank(_ daemon: Daemon, track name: String) async throws -> (track: TrackState, channel: Int) {
    let track = try await daemon.navigator.resolve(name)
    let channel = try await daemon.navigator.bank(toShow: track.index)
    // Re-read: banking refreshed volumeRaw in the model.
    let fresh = try await daemon.model.track(named: track.name)
    return (fresh, channel)
}

func trackArgSchema(_ extra: [String: Value], required: [String]) -> Value {
    var properties: [String: Value] = ["track": .object([
        "type": .string("string"), "description": .string("Track name (case-insensitive; unique prefix ok)"),
    ])]
    for (key, value) in extra { properties[key] = value }
    return .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array((["track"] + required).map { .string($0) }),
    ])
}

public struct SetVolumeTool: LogicTool {
    public let name = "set_volume"
    public let description = "Set a track's volume fader. Pass exactly one of: db (absolute, -∞ as -100 … +6.0) or delta (relative dB). Returns the dB value Logic echoed back — ground truth, not the requested value."
    public let inputSchema = trackArgSchema([
        "db": .object(["type": .string("number")]),
        "delta": .object(["type": .string("number")]),
    ], required: [])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let db = args["db"]?.doubleValue
        let delta = args["delta"]?.doubleValue
        guard (db == nil) != (delta == nil) else {
            throw ToolFailure(error: "set_volume needs exactly one of 'db' or 'delta'", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)

        let targetDB: Double
        if let db {
            targetDB = db
        } else {
            guard let currentRaw = track.volumeRaw, let currentDB = FaderCurve.dB(fromRaw: currentRaw) else {
                throw ToolFailure(error: "current volume unknown; cannot apply delta", layer: "model",
                                  expected: "an observed fader position for '\(track.name)'",
                                  observed: "none — run refresh_state and retry")
            }
            targetDB = currentDB + delta!
        }

        let echoedRaw = try await daemon.session.moveFader(
            channel: channel, toRaw: FaderCurve.raw(fromDB: targetDB), timeout: .seconds(1))
        let echoedDB = FaderCurve.dB(fromRaw: echoedRaw)
        await daemon.model.updateTrack(index: track.index) {
            $0.volumeRaw = echoedRaw
            $0.volumeDB = echoedDB
            $0.volumeIsSilent = echoedRaw == 0
        }
        return .object([
            "track": .string(track.name),
            "volumeDB": echoedDB.map { Value.double($0) } ?? .null,
            "volumeRaw": .int(echoedRaw),
        ])
    }
}
```

Register `SetVolumeTool(daemon: self)` in `registerAllTools`.

- [ ] **Step 4: Run tests** — `swift test --filter ToolTests 2>&1 | tail -5` — PASS.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 12: `set_pan`, `set_mute`, `set_solo`, `set_automation_mode`

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/MixTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: `resolveAndBank`, `MCUSession.press/turnVPot/waitFor`, `ProjectModel.updateTrack`.
- Produces tools: `set_mute(track, on)`, `set_solo(track, on)`, `set_pan(track, position: -64…63)`, `set_automation_mode(track, mode: read|write|touch|latch)`.

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testSetMuteOnAndIdempotent() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_mute",
                                     arguments: ["track": .string("Snare"), "on": .bool(true)])
    let json = try resultJSON(result)
    XCTAssertEqual(json["mute"] as? Bool, true)
    var state = await fake.state
    XCTAssertTrue(state[1].mute)
    // Setting the same value again must NOT toggle it back off.
    _ = await registry.call(name: "set_mute",
                            arguments: ["track": .string("Snare"), "on": .bool(true)])
    state = await fake.state
    XCTAssertTrue(state[1].mute)
}

func testSetSolo() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "set_solo",
                            arguments: ["track": .string("Bass"), "on": .bool(true)])
    let state = await fake.state
    XCTAssertTrue(state[6].solo)
}

func testSetPanVerifiedByRing() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_pan",
                                     arguments: ["track": .string("Keys"), "position": .int(-30)])
    XCTAssertNotEqual(result.isError, true)
    let state = await fake.state
    XCTAssertEqual(state[9].pan, 34)   // 64 + (-30)
}

func testSetAutomationMode() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_automation_mode",
                                     arguments: ["track": .string("Vocal"), "mode": .string("latch")])
    XCTAssertNotEqual(result.isError, true)
    let state = await fake.state
    XCTAssertEqual(state[10].automationMode, "latch")
}
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement** (append to `MixTools.swift`):

```swift
/// Mute and solo share the toggle-until-LED-matches shape.
func setToggle(_ daemon: Daemon, trackName: String, on: Bool,
               button: @escaping @Sendable (Int) -> MCUButton,
               read: @escaping @Sendable (TrackState) -> Bool,
               write: @escaping @Sendable (inout TrackState, Bool) -> Void,
               label: String) async throws -> Value {
    let (track, channel) = try await resolveAndBank(daemon, track: trackName)
    let current = await daemon.session.surface.leds[button(channel)] == .on
    if current != on {
        async let led = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .led(let b, let s) = $0 { return b == button(channel) && s == (on ? .on : .off) }
            return false
        }
        await daemon.session.press(button(channel))
        guard await led != nil else {
            throw ToolFailure(error: "\(label) not confirmed", layer: "mcu",
                              expected: "\(label) LED \(on ? "on" : "off") for '\(track.name)'",
                              observed: "no LED echo within 1s")
        }
    }
    await daemon.model.updateTrack(index: track.index) { write(&$0, on) }
    return .object(["track": .string(track.name), label.contains("mute") ? "mute" : "solo": .bool(on)])
}

public struct SetMuteTool: LogicTool {
    public let name = "set_mute"
    public let description = "Mute or unmute a track. Idempotent; verified by Logic's mute-LED echo."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggle(daemon, trackName: trackName, on: on,
                                   button: { .mute(channel: $0) },
                                   read: { $0.mute }, write: { $0.mute = $1 }, label: "mute")
    }
}

public struct SetSoloTool: LogicTool {
    public let name = "set_solo"
    public let description = "Solo or unsolo a track. Idempotent; verified by Logic's solo-LED echo."
    public let inputSchema = trackArgSchema(["on": .object(["type": .string("boolean")])], required: ["on"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let on = args["on"]?.boolValue else {
            throw ToolFailure(error: "missing required argument 'on'", layer: "daemon")
        }
        return try await setToggle(daemon, trackName: trackName, on: on,
                                   button: { .solo(channel: $0) },
                                   read: { $0.solo }, write: { $0.solo = $1 }, label: "solo")
    }
}

public struct SetPanTool: LogicTool {
    public let name = "set_pan"
    public let description = "Set pan position, -64 (hard left) … 0 (center) … +63 (hard right). Verified by V-Pot ring echo."
    public let inputSchema = trackArgSchema(["position": .object(["type": .string("integer")])], required: ["position"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let position = args["position"]?.intValue, (-64...63).contains(position) else {
            throw ToolFailure(error: "'position' must be an integer in -64…63", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.assignPan)   // ensure V-Pots are in pan mode
        // Pan over MCU is delta-only: sweep hard left (-127 ticks ≥ full range), then tick up to target.
        async let ringSeen = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .vpotRing(channel, _) = $0 { return true } else { return false }
        }
        await daemon.session.turnVPot(channel: channel, ticks: -127)
        await daemon.session.turnVPot(channel: channel, ticks: position + 64)
        guard await ringSeen != nil else {
            throw ToolFailure(error: "pan not confirmed", layer: "mcu",
                              expected: "V-Pot ring echo on channel \(channel)", observed: "no echo within 1s")
        }
        await daemon.model.updateTrack(index: track.index) { $0.pan = position + 64 }
        return .object(["track": .string(track.name), "pan": .int(position)])
    }
}

public struct SetAutomationModeTool: LogicTool {
    public let name = "set_automation_mode"
    public let description = "Set a track's automation mode: read, write, touch, or latch. Selects the track first; verified by the automation button LED."
    public let inputSchema = trackArgSchema(["mode": .object([
        "type": .string("string"), "enum": .array([.string("read"), .string("write"), .string("touch"), .string("latch")]),
    ])], required: ["mode"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let mode = try requireString(args, "mode", tool: name)
        let button: MCUButton = switch mode {
        case "read": .automationRead
        case "write": .automationWrite
        case "touch": .automationTouch
        case "latch": .automationLatch
        default: throw ToolFailure(error: "mode must be read|write|touch|latch", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.select(channel: channel))   // automation buttons act on selection
        async let led = daemon.session.waitFor(timeout: .seconds(1)) {
            if case .led(button, .on) = $0 { return true } else { return false }
        }
        await daemon.session.press(button)
        guard await led != nil else {
            throw ToolFailure(error: "automation mode not confirmed", layer: "mcu",
                              expected: "\(mode) LED on", observed: "no LED echo within 1s")
        }
        return .object(["track": .string(track.name), "automationMode": .string(mode)])
    }
}
```

**Pan note:** MCU pan is relative (V-Pot deltas), so absolute positioning sweeps to a rail then counts up — 191 ticks worst case, still tens of ms over the wire. The ring echo (`1 + pan/12`, 11 coarse steps) is too coarse to verify the exact value; the ring confirms *the move landed*, the model stores the requested absolute. Real-Logic accuracy is checked in the Task 16 smoke (Logic's channel-strip readout).

Register all four in `registerAllTools`.

- [ ] **Step 4: Run tests** — `swift test --filter ToolTests 2>&1 | tail -5` — PASS.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 13: `set_send`

**Files:**
- Create: `Sources/LogicMCPCore/Tools/SendTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: `resolveAndBank`, `MCUSession.press/turnVPot/waitFor/settle`, `SurfaceState.lcdCell`.
- Produces: tool `set_send(track, bus, level: 0-127)` returning `{track, bus, level}` where `level` is parsed back off the LCD (ground truth).

**Flow:** resolve + bank → `press(.select(channel))` (send view shows the selected track's sends) → `press(.assignSend)` → `settle` → scan LCD top cells for the cell matching `bus` (trimmed, case-insensitive prefix) → V-Pot that cell to the target by delta (sweep-down then up, as pan) → `settle` → parse the bottom-line cell as the echoed integer level. Cell not found → `ToolFailure(…, expected: "a send to '\(bus)'", observed: "<top line>")`. Restore `press(.assignPan)` before returning (leave the surface in the default mode other tools assume).

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testSetSendLevel() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_send", arguments: [
        "track": .string("Vocal"), "bus": .string("Bus 2"), "level": .int(90),
    ])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["level"] as? Int, 90)
    let state = await fake.state
    XCTAssertEqual(state[10].sends[1].level, 90)
}

func testSetSendUnknownBus() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_send", arguments: [
        "track": .string("Vocal"), "bus": .string("Bus 9"), "level": .int(10),
    ])
    XCTAssertEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["layer"] as? String, "mcu")
}
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

`Sources/LogicMCPCore/Tools/SendTools.swift`:

```swift
import MCP

public struct SetSendTool: LogicTool {
    public let name = "set_send"
    public let description = "Set a send level (0-127) from a track to a bus. Uses the MCU send page; the returned level is read back off Logic's LCD."
    public let inputSchema = trackArgSchema([
        "bus": .object(["type": .string("string")]),
        "level": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(127)]),
    ], required: ["bus", "level"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let bus = try requireString(args, "bus", tool: name)
        guard let level = args["level"]?.intValue, (0...127).contains(level) else {
            throw ToolFailure(error: "'level' must be an integer in 0…127", layer: "daemon")
        }
        let (track, channel) = try await resolveAndBank(daemon, track: trackName)
        await daemon.session.press(.select(channel: channel))
        await daemon.session.press(.assignSend)
        await daemon.session.settle(.milliseconds(150))

        // Restore the pan view all other tools assume — awaited on every exit path
        // (a fire-and-forget defer would race the next tool call).
        func restoreMode() async { await daemon.session.press(.assignPan) }

        let surface = await daemon.session.surface
        let wanted = bus.lowercased()
        guard let cell = (0..<8).first(where: {
            surface.lcdCell(line: 0, channel: $0).trimmingCharacters(in: .whitespaces)
                .lowercased().hasPrefix(String(wanted.prefix(7)))
        }) else {
            await restoreMode()
            throw ToolFailure(error: "no send to '\(bus)' on '\(track.name)'", layer: "mcu",
                              expected: "a send cell matching '\(bus)'",
                              observed: surface.lcdTop)
        }

        await daemon.session.turnVPot(channel: cell, ticks: -127)         // to zero
        await daemon.session.turnVPot(channel: cell, ticks: level)        // up to target
        await daemon.session.settle(.milliseconds(150))

        let after = await daemon.session.surface
        let display = after.lcdCell(line: 1, channel: cell).trimmingCharacters(in: .whitespaces)
        await restoreMode()
        guard let echoed = Int(display) else {
            throw ToolFailure(error: "send level not confirmed", layer: "mcu",
                              expected: "numeric level in LCD cell \(cell)", observed: display)
        }
        return .object(["track": .string(track.name), "bus": .string(bus), "level": .int(echoed)])
    }
}
```

Register `SetSendTool(daemon: self)`.

**Real-Logic caveat for the smoke run (Task 16):** Logic's send page layout has variants (send-per-vpot for the selected channel vs. one send across all channels). The LCD-scan approach reads whichever labels Logic writes; if the real layout differs from FakeLogic's, adjust `FakeLogic.sendSendLCD` to match the captured transcript — the tool code reads labels, so it survives layout differences as long as bus names appear as cells.

- [ ] **Step 4: Run tests** — PASS. **Step 5: Stop — do not commit.**

---

### Task 14: `get_plugin_params` + `set_plugin_param`

**Files:**
- Create: `Sources/LogicMCPCore/Tools/PluginTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: `resolveAndBank`, session press/vpot/settle, `SurfaceState.lcdCell`.
- Produces:
  - `get_plugin_params(track, slot)` → `{track, slot, plugin, params: [{index, name, display}]}` — pages through the plugin edit view collecting all name/value cells.
  - `set_plugin_param(track, slot, param, value)` — `param` matches by LCD name (trimmed, case-insensitive prefix) or by integer index; `value` is normalized 0.0–1.0 turned into V-Pot ticks; returns `{param, display}` with the display string read back from the LCD.
  - Shared helper `enterPluginEdit(_ daemon: Daemon, track: String, slot: Int) async throws -> (track: TrackState, params: [(index: Int, name: String, display: String)])`.

**Paging protocol:** enter edit mode (select track → `.assignPlugin` → settle → `.vpotPress(slot)` → settle), read 8 cells/page, `.channelRight` to page (LCD unchanged ⇒ last page), `.channelLeft` back to page 0 when done. Terse names are expected (spec risk: "plugin parameter names via LCD are terse") — return them verbatim; the per-plugin name dictionary is a later-phase refinement.

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testGetPluginParamsPagesThroughAll() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "get_plugin_params",
                                     arguments: ["track": .string("Vocal"), "slot": .int(0)])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    let params = json["params"] as! [[String: Any]]
    XCTAssertEqual(params.count, 10)                       // ChanEQ fixture has 10 → proves paging
    XCTAssertEqual(params[0]["name"] as? String, "LowFrq")
    XCTAssertEqual(params[8]["name"] as? String, "HPFrq")  // page 2
}

func testSetPluginParamByName() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_plugin_param", arguments: [
        "track": .string("Vocal"), "slot": .int(0), "param": .string("HiGain"), "value": .double(0.75),
    ])
    XCTAssertNotEqual(result.isError, true)
    let json = try resultJSON(result)
    XCTAssertEqual(json["display"] as? String, "0.75")
    let state = await fake.state
    XCTAssertEqual(state[10].plugins[0].params[6].value, 0.75, accuracy: 0.03)
}

func testSetPluginParamUnknownName() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "set_plugin_param", arguments: [
        "track": .string("Vocal"), "slot": .int(0), "param": .string("Wobble"), "value": .double(0.5),
    ])
    XCTAssertEqual(result.isError, true)
}
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

`Sources/LogicMCPCore/Tools/PluginTools.swift`:

```swift
import MCP

struct PluginParamCell: Sendable {
    var index: Int
    var name: String
    var display: String
    var page: Int
    var channel: Int
}

func enterPluginEdit(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (track: TrackState, params: [PluginParamCell]) {
    let (track, channel) = try await resolveAndBank(daemon, track: trackName)
    await daemon.session.press(.select(channel: channel))
    await daemon.session.press(.assignPlugin)
    await daemon.session.settle(.milliseconds(150))
    await daemon.session.press(.vpotPress(channel: slot))
    await daemon.session.settle(.milliseconds(150))

    var params: [PluginParamCell] = []
    var page = 0
    while page < 16 {   // hard cap: 128 params
        let surface = await daemon.session.surface
        for ch in 0..<8 {
            let name = surface.lcdCell(line: 0, channel: ch).trimmingCharacters(in: .whitespaces)
            let display = surface.lcdCell(line: 1, channel: ch).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                params.append(PluginParamCell(index: page * 8 + ch, name: name,
                                              display: display, page: page, channel: ch))
            }
        }
        let before = surface.lcdTop
        await daemon.session.press(.channelRight)
        await daemon.session.settle(.milliseconds(150))
        if await daemon.session.surface.lcdTop == before { break }   // last page
        page += 1
    }
    if params.isEmpty {
        throw ToolFailure(error: "no plugin parameters visible", layer: "mcu",
                          expected: "plugin edit LCD for '\(trackName)' slot \(slot)",
                          observed: "blank LCD — is a plugin loaded in that slot?")
    }
    // Return to page 0 so a following set targets the right cells.
    for _ in 0..<page { await daemon.session.press(.channelLeft) }
    await daemon.session.settle(.milliseconds(150))
    return (track, params)
}

/// Leave plugin edit and restore the pan view all other tools assume.
func exitPluginEdit(_ daemon: Daemon) async {
    await daemon.session.press(.assignPan)
    await daemon.session.settle(.milliseconds(150))
}

public struct GetPluginParamsTool: LogicTool {
    public let name = "get_plugin_params"
    public let description = "List a plugin's parameters (names and displayed values) from the MCU plugin-edit view. Names are the LCD's 7-char abbreviations. slot is the 0-based insert position."
    public let inputSchema = trackArgSchema(["slot": .object(["type": .string("integer")])], required: ["slot"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.intValue, (0...7).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…7", layer: "daemon")
        }
        let (track, params) = try await enterPluginEdit(daemon, trackName: trackName, slot: slot)
        await exitPluginEdit(daemon)
        return .object([
            "track": .string(track.name),
            "slot": .int(slot),
            "params": .array(params.map { .object([
                "index": .int($0.index), "name": .string($0.name), "display": .string($0.display),
            ]) }),
        ])
    }
}

public struct SetPluginParamTool: LogicTool {
    public let name = "set_plugin_param"
    public let description = "Set one plugin parameter. param: LCD name (prefix ok) or integer index from get_plugin_params. value: normalized 0.0-1.0. Returns the display string Logic echoed."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("LCD param name or integer index")]),
        "value": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)]),
    ], required: ["slot", "param", "value"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.intValue, (0...7).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…7", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.intValue.map(String.init)
        guard let paramKey else {
            throw ToolFailure(error: "missing required argument 'param'", layer: "daemon")
        }
        guard let value = args["value"]?.doubleValue, (0.0...1.0).contains(value) else {
            throw ToolFailure(error: "'value' must be a number in 0.0…1.0", layer: "daemon")
        }

        let (_, params) = try await enterPluginEdit(daemon, trackName: trackName, slot: slot)
        let wanted = paramKey.lowercased()
        let target = params.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in params.first { $0.index == i } }
        guard let target else {
            await exitPluginEdit(daemon)
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "mcu",
                              expected: "one of: \(params.map(\.name).joined(separator: ", "))",
                              observed: "no matching LCD cell")
        }

        // Page to the target's page, then delta the V-Pot: full sweep down, then up to value.
        for _ in 0..<target.page { await daemon.session.press(.channelRight) }
        await daemon.session.settle(.milliseconds(150))
        await daemon.session.turnVPot(channel: target.channel, ticks: -127)
        await daemon.session.turnVPot(channel: target.channel, ticks: Int((value * 20).rounded()))
        await daemon.session.settle(.milliseconds(150))

        let display = await daemon.session.surface
            .lcdCell(line: 1, channel: target.channel).trimmingCharacters(in: .whitespaces)
        await exitPluginEdit(daemon)
        guard !display.isEmpty else {
            throw ToolFailure(error: "parameter change not confirmed", layer: "mcu",
                              expected: "updated value in LCD cell \(target.channel)", observed: "blank cell")
        }
        return .object(["param": .string(target.name), "display": .string(display)])
    }
}
```

**Tick scaling honesty:** the `value * 20` tick count matches FakeLogic's 0.05-per-tick model. Real Logic's per-tick step varies per parameter; the LCD display string is the ground truth either way (it's what the tool returns), and the Task 16 smoke documents observed per-tick behavior for stock plugins. Refining tick→value mapping (or a set-then-read-then-correct loop) is called out under "Later phases".

Register both tools.

- [ ] **Step 4: Run tests** — `swift test --filter ToolTests 2>&1 | tail -5` — PASS.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 15: Undo journal + `undo_last`

**Files:**
- Create: `Sources/LogicMCPCore/Model/UndoJournal.swift`
- Create: `Sources/LogicMCPCore/Tools/UndoTool.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (add `journal` property, register tool)
- Modify: `Sources/LogicMCPCore/Tools/MixTools.swift`, `SendTools.swift`, `PluginTools.swift` (record mutations)
- Test: `Tests/LogicMCPCoreTests/ToolTests.swift` (extend)

**Interfaces:**
- Consumes: everything above.
- Produces:

```swift
public struct MixMutation: Sendable, Codable {
    public var tool: String            // "set_volume", "set_pan", …
    public var track: String
    public var undoArguments: [String: String]?  // nil ⇒ not deterministically undoable
    public var descriptionText: String // human-readable, e.g. "Vocal volume -6.2 → -4.0 dB"
}

public actor UndoJournal {
    public func record(_ mutation: MixMutation)
    public func popLast(_ n: Int) -> [MixMutation]
    public var entries: [MixMutation] { get }
}
```

- Tool `undo_last(n = 1)`: pops the last *n* mutations and replays each `undoArguments` through the registry (`set_volume` with the prior dB, `set_mute` with the prior state, …). Entries with `undoArguments == nil` (e.g. `set_plugin_param`, where the prior value is a display string, not a settable number) are reported as `skipped` in the result: `{undone: [...], skipped: [...]}` — spec: mix moves restore deterministically; other layers fall back to checkpoint/⌘Z in later phases.
- **Recording rule** (applies inside each mutating tool, after verification succeeds): record with the *prior* value captured before the move. `set_volume` records `["track": name, "db": String(priorDB)]` (prior unknown/−∞ ⇒ `undoArguments = nil`); `set_pan` records prior position; `set_mute`/`set_solo` record prior boolean; `set_send` records prior LCD level if it was parsed before the move (read the bottom cell before turning; else nil); `set_plugin_param` records nil.

- [ ] **Step 1: Write the failing tests** (append to `ToolTests.swift`):

```swift
func testUndoLastRestoresVolume() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-6.0)])
    _ = await registry.call(name: "set_volume", arguments: ["track": .string("Vocal"), "db": .double(-2.0)])
    let result = await registry.call(name: "undo_last", arguments: [:])
    XCTAssertNotEqual(result.isError, true)
    let state = await fake.state
    XCTAssertEqual(state[10].volumeRaw, FaderCurve.raw(fromDB: -6.0))
}

func testUndoLastTwoSpansTools() async throws {
    let (_, registry, fake) = await makeDaemonWithFakeLogic()
    _ = await registry.call(name: "set_mute", arguments: ["track": .string("Bass"), "on": .bool(true)])
    _ = await registry.call(name: "set_volume", arguments: ["track": .string("Kick"), "db": .double(-9.0)])
    _ = await registry.call(name: "undo_last", arguments: ["n": .int(2)])
    let state = await fake.state
    XCTAssertFalse(state[6].mute)                    // mute undone
    XCTAssertEqual(state[0].volumeRaw, 12288)        // volume back to initial 0 dB
}

func testUndoEmptyJournal() async throws {
    let (_, registry, _) = await makeDaemonWithFakeLogic()
    let result = await registry.call(name: "undo_last", arguments: [:])
    let json = try resultJSON(result)
    XCTAssertEqual((json["undone"] as! [Any]).count, 0)
}
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

`Sources/LogicMCPCore/Model/UndoJournal.swift`:

```swift
public struct MixMutation: Sendable, Codable {
    public var tool: String
    public var track: String
    public var undoArguments: [String: String]?
    public var descriptionText: String
    public init(tool: String, track: String, undoArguments: [String: String]?, descriptionText: String) {
        self.tool = tool
        self.track = track
        self.undoArguments = undoArguments
        self.descriptionText = descriptionText
    }
}

public actor UndoJournal {
    public private(set) var entries: [MixMutation] = []
    public init() {}
    public func record(_ mutation: MixMutation) { entries.append(mutation) }
    public func popLast(_ n: Int) -> [MixMutation] {
        let count = min(n, entries.count)
        let popped = Array(entries.suffix(count).reversed())
        entries.removeLast(count)
        return popped
    }
}
```

`Sources/LogicMCPCore/Tools/UndoTool.swift`:

```swift
import MCP

public struct UndoLastTool: LogicTool {
    public let name = "undo_last"
    public let description = "Undo the last n mix mutations made through this daemon by restoring their prior values over the MCU wire. Plugin-param changes cannot be deterministically restored and are reported as skipped."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["n": .object(["type": .string("integer"), "default": .int(1)])]),
    ])
    let daemon: Daemon
    let registry: ToolRegistry

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let n = args["n"]?.intValue ?? 1
        var undone: [Value] = []
        var skipped: [Value] = []
        for mutation in await daemon.journal.popLast(n) {
            guard let undoArgs = mutation.undoArguments else {
                skipped.append(.string(mutation.descriptionText))
                continue
            }
            var callArgs: [String: Value] = [:]
            for (key, raw) in undoArgs {
                if raw == "true" || raw == "false" { callArgs[key] = .bool(raw == "true") }
                else if let d = Double(raw), key != "track", key != "bus", key != "param" {
                    callArgs[key] = key == "level" || key == "position" ? .int(Int(d)) : .double(d)
                } else { callArgs[key] = .string(raw) }
            }
            let result = await registry.call(name: mutation.tool, arguments: callArgs)
            if result.isError == true {
                skipped.append(.string("\(mutation.descriptionText) — undo failed"))
            } else {
                undone.append(.string(mutation.descriptionText))
            }
        }
        return .object(["undone": .array(undone), "skipped": .array(skipped)])
    }
}
```

`Daemon` gains `public let journal = UndoJournal()` and registers `UndoLastTool(daemon: self, registry: registry)` (note: undoing must not re-record — add `let recordUndo: Bool` plumbing? No: `popLast` already removed the entries, and the replayed tools will record fresh entries; that makes "redo by undoing the undo" work naturally. Leave it.).

Recording in `SetVolumeTool.invoke` (after the model update, before `return`):

```swift
let priorDB = track.volumeDB
await daemon.journal.record(MixMutation(
    tool: "set_volume", track: track.name,
    undoArguments: priorDB.map { ["track": track.name, "db": String($0)] },
    descriptionText: "\(track.name) volume \(priorDB.map { String($0) } ?? "-∞") → \(echoedDB.map { String($0) } ?? "-∞") dB"))
```

Recording in `setToggle` (mute/solo, after LED verification, using the model's prior value read before pressing — capture `let prior = read(track)` at the top):

```swift
await daemon.journal.record(MixMutation(
    tool: label.contains("mute") ? "set_mute" : "set_solo", track: track.name,
    undoArguments: ["track": track.name, "on": prior ? "true" : "false"],
    descriptionText: "\(track.name) \(label) \(prior) → \(on)"))
```

Recording in `SetPanTool` (prior from `track.pan`, nil-safe like volume), in `SetSendTool` (parse the bottom cell *before* turning; if unparseable use `undoArguments: nil`), and in `SetPluginParamTool` (`undoArguments: nil`, description from the pre-move display).

- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` — full suite PASS.

- [ ] **Step 5: Stop — task complete, do not commit.**

---

### Task 16: `capture` subcommand + real-Logic integration smoke

The bridge from FakeLogic to reality: a transcript recorder for golden fixtures and fader calibration, plus the documented manual gate.

**Files:**
- Modify: `Sources/logic-mcp/Main.swift` (add `Capture` subcommand)
- Create: `docs/integration-smoke.md`
- Test: none new (this task produces the *procedure*; its output — captured transcripts — feeds back into `Tests/LogicMCPCoreTests/Fixtures/`)

**Interfaces:**
- Consumes: `CoreMIDIWire`, `Transcript`, `MCUSession`.
- Produces: `logic-mcp capture --out <file.jsonl>` — opens the virtual ports, responds to the MCU handshake (so Logic engages), and appends every message in both directions to the JSONL transcript until Ctrl-C.

- [ ] **Step 1: Implement the subcommand** (add to `Main.swift`, and add `Capture.self` to `subcommands:`):

```swift
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
```

Note `Transcript.hex` and `TranscriptEntry` come from Task 4. Build check: `swift build 2>&1 | tail -3` → `Build complete!`.

- [ ] **Step 2: Write the integration smoke document**

`docs/integration-smoke.md`:

```markdown
# Integration smoke — real Logic Pro

Manual gate. Run on every Logic Pro update and before tagging a release.
Prereqs: Logic Pro open with a test project of ≥10 named tracks; daemon built
(`swift build`).

## One-time control-surface setup
1. Run `.build/debug/logic-mcp capture --out /tmp/setup.jsonl` (creates the
   virtual ports; leave it running).
2. Logic → Control Surfaces → Setup… → New → Install… → Mackie Designs |
   Mackie Control → Add. Set Output Port and Input Port to "logic-mcp MCU".
3. Confirm the transcript records LCD SysEx (track names) — that's Logic
   adopting the surface. Ctrl-C.

## Smoke checklist (via any MCP client pointed at `.build/debug/logic-mcp serve`)
| # | Call | Verify in Logic |
|---|------|-----------------|
| 1 | `ping` | returns ok |
| 2 | `refresh_state` | returned names match the project's first-7-chars track names, in order |
| 3 | `set_volume {track, db: -6}` | channel fader moves; Logic shows −6.0 ±0.5 dB |
| 4 | `set_volume {track, delta: +2}` | fader lands at −4.0 ±0.5 dB; tool returns ≈ −4.0 |
| 5 | `set_mute {on: true}` then `{on: false}` | mute button lights, then clears; idempotent re-call is a no-op |
| 6 | `set_pan {position: -30}` | channel strip shows ≈ L30 (see pan note, Task 12) |
| 7 | `set_send {bus, level: 90}` | send knob moves; tool's `level` matches Logic's readout |
| 8 | `play` / `stop` | transport runs/stops; tool returns verified state |
| 9 | `record` without confirm | refuses (structured error) |
| 10 | `get_plugin_params` on a Channel EQ | param names/displays match the plugin header readouts |
| 11 | `set_plugin_param` | knob moves in the plugin UI; returned display matches |
| 12 | `undo_last {n: 3}` | the last three mix moves visibly revert |
| 13 | Background test: hide Logic behind another app, repeat #3 | still works (MCU needs no focus) |

Record outcomes in this file's log section with the Logic version.

## Fader calibration (updates `FaderCurve.anchors`)
1. `logic-mcp capture --out /tmp/sweep.jsonl` with the surface installed.
2. In Logic, drag one fader slowly to each of: +6, +3, 0, −6, −12, −21, −30,
   −42, −54, −72, then to −∞. Type exact values into the volume field
   (double-click it) so each is precise; pause ~1s between values.
3. For each pause, take the last `E0`-status "in" line, decode raw = hh<<7|ll,
   and replace the matching `FaderCurve.anchors` entry.
4. `swift test --filter FaderCurveTests` must still pass (monotonic, round-trip).

## Send/plugin transcript fixtures
While captured: press SEND and PLUG-IN assignment modes from the tool flows
(`set_send`, `get_plugin_params`) and save the transcripts to
`Tests/LogicMCPCoreTests/Fixtures/` (e.g. `send_page.jsonl`,
`plugin_edit.jsonl`). If real layouts differ from FakeLogic's, update
FakeLogic to match the transcript and re-run the suite.

## Log
| Date | Logic version | Result | Notes |
|------|---------------|--------|-------|
```

- [ ] **Step 3: Run the smoke** (requires a Mac with Logic Pro): follow the checklist top to bottom; fix divergences by adjusting FakeLogic/fixtures to match captured reality (tests stay green), never by loosening verification.

- [ ] **Step 4: Update `FaderCurve.anchors`** from the calibration sweep; run `swift test 2>&1 | tail -3` — full suite PASS.

- [ ] **Step 5: Stop — task complete, do not commit.** Phase 1 is done: this is the "mix moves via chat" demo. Suggested demo script: `refresh_state` → "bring the vocal down 2 dB" → `set_volume("Vocal", delta: -2)` → `undo_last`.

---

## Later phases (separate plans, per spec phasing)

- **Phase 2 — FileGateway:** stem/bundle audio access, `analyze_audio` (onsets/spectrum/key/tuning via Accelerate), `compare_timing`, MIDI SMF codec + `import_midi`/`export_midi`. Independent of AX; needs only file access.
- **Phase 3 — AXDriver:** canonical key-command set install, AX-tree walking, `create_track`, `insert_plugin`, `set_output`, `create_bus_send`, `select_region`, `quantize_selection`, `enable_flex`, `run_key_command`, `checkpoint` (Project Alternatives) + auto-checkpoint rule, `undo_last` fallback to ⌘Z, **`locate(bar)` and `set_cycle(start,end)`** (deferred from Task 10), full-track-name reconciliation for the shadow model (replaces LCD-name matching from Task 8), focus discipline (activity detection + queueing), versioned AX adapter manifest + degraded-capability reporting.
- **Phase 4 — VisionVerifier + polish:** ScreenCaptureKit `screenshot(target)`, screenshots attached to structured errors, shadow model as an MCP resource, skill packs (`mix-cookbook`, `analysis-interpretation`), notarized distribution, guided setup experience.
- **Phase 1 refinements parked:** per-plugin parameter name dictionary; tick→value mapping per stock plugin (or verify-and-correct loop in `set_plugin_param`); LCD value parsing for exact dB readback; meter streaming.

## Self-review notes (spec ⇄ plan)

- Spec **Query** group: `get_project_overview` ✅ T9, `get_track` ✅ T9, `refresh_state` ✅ T9, `get_plugin_params` ✅ T14; `screenshot` → Phase 4 (vision layer, correctly out of this phase).
- Spec **Mix** group: `set_volume` ✅ T11, `set_pan`/`set_mute`/`set_solo`/`set_automation_mode` ✅ T12, `set_send` ✅ T13, `set_plugin_param` ✅ T14; transport `play`/`stop`/`record` ✅ T10; `locate`/`set_cycle` explicitly re-scoped to Phase 3 with rationale (T10 note) — **deliberate deviation, approve or push back at T10 review**.
- Spec **Structure/Content** groups: Phases 2–3 by design (CLAUDE.md phasing).
- Safety model: record-confirm ✅ T10; undo journal ✅ T15; checkpoints are AX-driven → Phase 3; focus discipline trivially satisfied (MCU never takes focus).
- Error contract `{error, layer, expected, observed}` ✅ T1, used by every tool; `screenshot?` field joins in Phase 4.
- Testing section of spec: golden-transcript unit rig ✅ T4/T16, FakeLogic scenario suite ✅ T5+, real-Logic smoke gate ✅ T16.
- Risks: LCD truncation → T8 resolution rules + honest ambiguity test; MCU protocol effort → T2–T7 decomposition; terse plugin names → T14 returns verbatim + parked dictionary.







