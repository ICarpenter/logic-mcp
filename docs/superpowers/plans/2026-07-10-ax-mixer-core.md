# AX Mixer Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Accessibility (AX) the primary, no-focus read/write and self-verification path for Logic Pro's mixer, re-homing the mixer read and the core mix write tools (and, via captured fixtures, the three currently-broken send/plugin tools) off MCU and onto AX.

**Architecture:** Three new units compose onto the existing `Daemon`: an `AXProvider` protocol (with a real `SystemAXProvider` over `AXUIElement` and an in-memory `FakeAXTree` for unit tests), an `AXBridge` actor that locates the mixer and reads/writes strips by full track name, and an `AXMixer` that pulls the whole mixer into the existing `ProjectModel`. Tools keep their MCP names and schemas; only the implementation behind them swaps to AX. MCU is retained for transport/metering and is demoted (its `settle()` gets a deadline; its dangerous plugin/send paths are switched off).

**Tech Stack:** Swift 6, `ApplicationServices` (`AXUIElement`), swift-mcp-sdk, swift-argument-parser, XCTest.

## Global Constraints

- **Platform:** macOS 14+, Swift tools 6.0 (from `Package.swift` — do not change).
- **No-focus invariant:** no code in the AX mixer path may activate Logic or set `kAXFrontmost`/`AXMain`. Unit tests assert the provider is never asked to activate.
- **Verified ground truth:** every write tool returns a value re-read from AX after the write; on mismatch it throws `ToolFailure`. Never fabricate data.
- **Structured errors only:** failures throw `ToolFailure(error:layer:expected:observed:)` with `layer` one of `"ax" | "mcu" | "model" | "daemon"` (add `"ax"` to the existing set).
- **Selectors key on `role` + `description` (+ `subrole`/`title`/`value`), NEVER on `AXIdentifier`** (the `_NS:48`-style ids are per-build unstable).
- **No auto-commits of anything but plan-produced code at the step's own commit.** The user controls integration commits; the per-task commits below stay on the branch.
- **Test hygiene (from `.superpowers/sdd/HANDOFF.md`):** hard-timeout every test run — macOS has no `timeout`; use `perl -e 'alarm 600; exec @ARGV' swift test …`. Run `pkill -f xctest` before a run to clear orphans. Tests that own a fake must **retain** it (no `_ =`).
- **Only one process may hold the virtual MIDI port.** `axdump` does NOT touch MIDI, so it may run while `serve` is live — but stop `serve` if a task also exercises MCU.

---

## File structure

**New (Sources/LogicMCPCore/AX/):**
- `AXProvider.swift` — the `AXProvider` protocol, the `AXHandle` element box, and the `AXAttr` key enum.
- `SystemAXProvider.swift` — real `AXUIElement` implementation.
- `AXBridge.swift` — the actor: locate mixer, find strip by name, read/write strip controls.
- `AXMixer.swift` — read the whole mixer into `ProjectModel`; per-strip accessors for tools.
- `AXStrip.swift` — the `AXStripControls` value type + dB-title parsing.

**New (Sources/logic-mcp/):**
- `AXDump.swift` — the `axdump` CLI subcommand.

**New (Tests/LogicMCPCoreTests/):**
- `FakeAXTree.swift` — in-memory AX tree + `FakeAXProvider`.
- `AXBridgeTests.swift`, `AXMixerTests.swift`, `AXMixToolTests.swift`, `AXStripTests.swift`.
- `Fixtures/ax/` — captured real-Logic dumps from Task 2 (`mixer_strip.txt`, `plugin_window.txt`, `send_page.txt`).

**Modified:**
- `Sources/LogicMCPCore/Daemon.swift` — hold `ax: AXBridge` + `axMixer: AXMixer`; inject an `AXProvider` (default `SystemAXProvider`).
- `Sources/LogicMCPCore/MCU/MCUSession.swift:123` — deadline `settle()`.
- `Sources/LogicMCPCore/Tools/MixTools.swift` — `set_volume/set_pan/set_mute/set_solo` → AX.
- `Sources/LogicMCPCore/Tools/QueryTools.swift` — `refresh_state/get_project_overview/get_track` → AX.
- `Sources/LogicMCPCore/Tools/SendTools.swift`, `PluginTools.swift` — AX implementations; old MCU paths switched off.
- `Sources/LogicMCPCore/Model/ProjectModel.swift` — add `output: String?` to `TrackState`.
- `Sources/logic-mcp/Main.swift:11` — register `AXDump` subcommand.

---

## Task 1: `AXProvider` protocol + `FakeAXTree` (the test seam)

**Files:**
- Create: `Sources/LogicMCPCore/AX/AXProvider.swift`
- Create: `Tests/LogicMCPCoreTests/FakeAXTree.swift`
- Test: `Tests/LogicMCPCoreTests/AXBridgeTests.swift` (the fake's own sanity test lives here temporarily; renamed in Task 3)

**Interfaces:**
- Produces:
  - `struct AXHandle: Hashable, @unchecked Sendable` — opaque element reference.
  - `enum AXAttr: String { case role, subrole, description, title, value, help }`
  - `enum AXAction: String { case press = "AXPress", increment = "AXIncrement", decrement = "AXDecrement" }`
  - `protocol AXProvider: Sendable` with:
    - `func root() throws -> AXHandle`
    - `func children(of: AXHandle) -> [AXHandle]`
    - `func string(_ attr: AXAttr, of: AXHandle) -> String?`
    - `func number(of: AXHandle) -> Double?`  // kAXValueattribute as a number
    - `func isSettable(_ h: AXHandle) -> Bool`
    - `func setNumber(_ v: Double, of: AXHandle) throws`
    - `func perform(_ action: AXAction, on: AXHandle) throws`
    - `func windows() -> [AXHandle]`
  - `struct AXUnavailable: Error` — thrown by `root()` when the app/permission is missing.
  - `final class FakeAXNode` + `final class FakeAXProvider: AXProvider` (test target).

- [ ] **Step 1: Write the failing test** (`Tests/LogicMCPCoreTests/AXBridgeTests.swift`)

```swift
import XCTest
@testable import LogicMCPCore

final class FakeAXTreeSanityTests: XCTestCase {
    /// A minimal mixer: one window holding an AXLayoutArea "Mixer" with one strip "vox".
    func makeMixer() -> FakeAXProvider {
        let volTitle = FakeAXNode(role: "AXStaticText", title: "volume fader level, 0.0 dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true)
        let mute = FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off")
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox",
                               children: [mute, vol, volTitle])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
    }

    func testProviderReadsRoleAndDescription() throws {
        let p = makeMixer()
        let window = p.windows().first!
        let area = p.children(of: window).first!
        XCTAssertEqual(p.string(.description, of: area), "Mixer")
        let strip = p.children(of: area).first!
        XCTAssertEqual(p.string(.role, of: strip), "AXLayoutItem")
        XCTAssertEqual(p.string(.description, of: strip), "vox")
    }

    func testPerformPressFlipsSwitchValue() throws {
        let p = makeMixer()
        let strip = p.children(of: p.children(of: p.windows().first!).first!).first!
        let mute = p.children(of: strip).first { p.string(.description, of: $0) == "mute" }!
        XCTAssertEqual(p.string(.value, of: mute), "off")
        try p.perform(.press, on: mute)
        XCTAssertEqual(p.string(.value, of: mute), "on")
    }

    func testSetNumberUpdatesSettableSlider() throws {
        let p = makeMixer()
        let strip = p.children(of: p.children(of: p.windows().first!).first!).first!
        let vol = p.children(of: strip).first { p.string(.description, of: $0) == "volume fader" }!
        XCTAssertTrue(p.isSettable(vol))
        try p.setNumber(200, of: vol)
        XCTAssertEqual(p.number(of: vol), 200)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter FakeAXTreeSanityTests`
Expected: FAIL — `cannot find 'FakeAXNode' / 'FakeAXProvider' / 'AXAttr' in scope`.

- [ ] **Step 3: Write the protocol** (`Sources/LogicMCPCore/AX/AXProvider.swift`)

```swift
import Foundation

/// Opaque reference to one accessibility element. Boxes either a real `AXUIElement`
/// (held as `AnyObject` so this file needs no `ApplicationServices` import) or a fake
/// node identity. `@unchecked Sendable`: `AXUIElement` is a CF type that is not
/// formally Sendable, but every touch of it is confined to the `AXBridge` actor, so
/// crossing the provider boundary is safe in practice — same pattern as `CoreMIDIWire`.
public struct AXHandle: Hashable, @unchecked Sendable {
    let system: AnyObject?
    let fake: ObjectIdentifier?
    init(system: AnyObject) { self.system = system; self.fake = nil }
    init(fake: AnyObject) { self.system = nil; self.fake = ObjectIdentifier(fake) }
    public static func == (a: AXHandle, b: AXHandle) -> Bool {
        if let x = a.system, let y = b.system { return x === y }
        return a.fake == b.fake
    }
    public func hash(into h: inout Hasher) {
        if let s = system { h.combine(ObjectIdentifier(s)) } else { h.combine(fake) }
    }
}

public enum AXAttr: String {
    case role, subrole, description, title, value, help
}

public enum AXAction: String {
    case press = "AXPress", increment = "AXIncrement", decrement = "AXDecrement"
}

/// Thrown when Logic (or Accessibility permission) is unavailable.
public struct AXUnavailable: Error { public init() {} }

/// Narrow surface over the AX operations the mixer needs. `SystemAXProvider` wraps the
/// real C API; `FakeAXProvider` (test target) backs unit tests. Providers MUST NOT
/// activate Logic or set frontmost — the no-focus invariant.
public protocol AXProvider: Sendable {
    func root() throws -> AXHandle
    func windows() -> [AXHandle]
    func children(of h: AXHandle) -> [AXHandle]
    func string(_ attr: AXAttr, of h: AXHandle) -> String?
    func number(of h: AXHandle) -> Double?
    func isSettable(_ h: AXHandle) -> Bool
    func setNumber(_ v: Double, of h: AXHandle) throws
    func perform(_ action: AXAction, on h: AXHandle) throws
}
```

- [ ] **Step 4: Write the fake** (`Tests/LogicMCPCoreTests/FakeAXTree.swift`)

```swift
import Foundation
@testable import LogicMCPCore

/// One node in an in-memory AX tree that mirrors the roles/descriptions/values real
/// Logic exposes. `perform(.press)` on an AXSwitch flips its value off<->on, so tool
/// logic that "press only if the state differs, then re-read" is exercised faithfully.
final class FakeAXNode {
    let role: String
    let subrole: String?
    let description: String?
    var title: String?
    var stringValue: String?
    var numberValue: Double?
    let settable: Bool
    var children: [FakeAXNode]

    init(role: String, subrole: String? = nil, description: String? = nil,
         title: String? = nil, stringValue: String? = nil, value: Double? = nil,
         settable: Bool = false, children: [FakeAXNode] = []) {
        self.role = role; self.subrole = subrole; self.description = description
        self.title = title; self.stringValue = stringValue; self.numberValue = value
        self.settable = settable; self.children = children
    }
}

final class FakeAXProvider: AXProvider, @unchecked Sendable {
    let rootNode: FakeAXNode
    private var byHandle: [AXHandle: FakeAXNode] = [:]
    /// Set by a test to assert the no-focus invariant is never breached.
    private(set) var activateCount = 0

    init(root: FakeAXNode) {
        self.rootNode = root
        index(root)
    }
    private func index(_ n: FakeAXNode) {
        byHandle[AXHandle(fake: n)] = n
        n.children.forEach(index)
    }
    private func node(_ h: AXHandle) -> FakeAXNode? { byHandle[h] }

    func root() throws -> AXHandle { AXHandle(fake: rootNode) }
    func windows() -> [AXHandle] {
        rootNode.children.filter { $0.role == "AXWindow" }.map { AXHandle(fake: $0) }
    }
    func children(of h: AXHandle) -> [AXHandle] {
        (node(h)?.children ?? []).map { AXHandle(fake: $0) }
    }
    func string(_ attr: AXAttr, of h: AXHandle) -> String? {
        guard let n = node(h) else { return nil }
        switch attr {
        case .role: return n.role
        case .subrole: return n.subrole
        case .description: return n.description
        case .title: return n.title
        case .help: return nil
        case .value: return n.stringValue ?? n.numberValue.map { String($0) }
        }
    }
    func number(of h: AXHandle) -> Double? { node(h)?.numberValue }
    func isSettable(_ h: AXHandle) -> Bool { node(h)?.settable ?? false }
    func setNumber(_ v: Double, of h: AXHandle) throws {
        guard let n = node(h), n.settable else { throw AXUnavailable() }
        n.numberValue = v
    }
    func perform(_ action: AXAction, on h: AXHandle) throws {
        guard let n = node(h) else { throw AXUnavailable() }
        switch action {
        case .press where n.subrole == "AXSwitch":
            n.stringValue = (n.stringValue == "on") ? "off" : "on"
        case .increment: n.numberValue = (n.numberValue ?? 0) + 10
        case .decrement: n.numberValue = (n.numberValue ?? 0) - 10
        case .press: break
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter FakeAXTreeSanityTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXProvider.swift Tests/LogicMCPCoreTests/FakeAXTree.swift Tests/LogicMCPCoreTests/AXBridgeTests.swift
git commit -m "feat(ax): AXProvider protocol and in-memory FakeAXTree test seam"
```

---

## Task 2: `SystemAXProvider` + `axdump` CLI, and capture real-Logic fixtures

This task is the AX analog of `lcdprobe`. Its deliverable is BOTH the real provider and a set of committed fixture dumps that later tasks build their fakes from. **Requires Logic Pro open with `mcp_test` and the Mixer window visible; the host terminal must hold Accessibility permission.**

**Files:**
- Create: `Sources/LogicMCPCore/AX/SystemAXProvider.swift`
- Create: `Sources/logic-mcp/AXDump.swift`
- Modify: `Sources/logic-mcp/Main.swift:11` (register subcommand)
- Create (captured output, committed): `Tests/LogicMCPCoreTests/Fixtures/ax/mixer_strip.txt`, `plugin_window.txt`, `send_page.txt`

**Interfaces:**
- Consumes: `AXProvider`, `AXHandle`, `AXAttr`, `AXAction`, `AXUnavailable` (Task 1).
- Produces: `final class SystemAXProvider: AXProvider` with `init(bundlePrefix: String = "com.apple.logic")`.

- [ ] **Step 1: Write `SystemAXProvider`** (`Sources/LogicMCPCore/AX/SystemAXProvider.swift`)

```swift
import ApplicationServices
import Cocoa

/// Real `AXUIElement`-backed provider. Read-only except `perform`/`setNumber`. Never
/// activates Logic (no `AXFrontmost`, no `NSRunningApplication.activate`).
public final class SystemAXProvider: AXProvider, @unchecked Sendable {
    private let app: AXUIElement
    public init(bundlePrefix: String = "com.apple.logic") throws {
        guard AXIsProcessTrusted() else { throw AXUnavailable() }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.hasPrefix(bundlePrefix) == true
        }) else { throw AXUnavailable() }
        self.app = AXUIElementCreateApplication(running.processIdentifier)
    }

    private func raw(_ h: AXHandle) -> AXUIElement { h.system as! AXUIElement }

    public func root() throws -> AXHandle { AXHandle(system: app) }

    public func windows() -> [AXHandle] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.map { AXHandle(system: $0) }
    }
    public func children(of h: AXHandle) -> [AXHandle] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.map { AXHandle(system: $0) }
    }
    public func string(_ attr: AXAttr, of h: AXHandle) -> String? {
        let key: String = switch attr {
        case .role: kAXRoleAttribute as String
        case .subrole: kAXSubroleAttribute as String
        case .description: kAXDescriptionAttribute as String
        case .title: kAXTitleAttribute as String
        case .value: kAXValueAttribute as String
        case .help: kAXHelpAttribute as String
        }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), key as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    public func number(of h: AXHandle) -> Double? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), kAXValueAttribute as CFString, &v) == .success,
              let n = v as? NSNumber else { return nil }
        return n.doubleValue
    }
    public func isSettable(_ h: AXHandle) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(raw(h), kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }
    public func setNumber(_ v: Double, of h: AXHandle) throws {
        let r = AXUIElementSetAttributeValue(raw(h), kAXValueAttribute as CFString, v as CFNumber)
        if r != .success { throw AXUnavailable() }
    }
    public func perform(_ action: AXAction, on h: AXHandle) throws {
        let r = AXUIElementPerformAction(raw(h), action.rawValue as CFString)
        if r != .success { throw AXUnavailable() }
    }
}
```

- [ ] **Step 2: Write the `axdump` subcommand** (`Sources/logic-mcp/AXDump.swift`)

```swift
import ArgumentParser
import Foundation
import LogicMCPCore

struct AXDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "axdump",
        abstract: "Dump Logic's accessibility tree (AX analog of lcdprobe). Read-only walk.")

    @Argument(help: "mode: tree | strip <name> | plugin <name> <slot> | send <name>")
    var args: [String] = ["tree"]

    func run() async throws {
        let p = try SystemAXProvider()
        let mode = args.first ?? "tree"
        switch mode {
        case "tree":
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 5) }
        case "strip", "send":
            guard args.count >= 2, let strip = findStrip(p, named: args[1]) else {
                print("strip '\(args.dropFirst().first ?? "?")' not found"); return
            }
            dump(p, strip, depth: 0, maxDepth: 4)
        case "plugin":
            print("Open the plugin window in Logic first, then run `axdump tree` and locate")
            print("the plugin window; this mode just re-dumps all windows for capture:")
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 6) }
        default:
            print("unknown mode '\(mode)'")
        }
    }

    private func findStrip(_ p: SystemAXProvider, named: String) -> AXHandle? {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 8 { return nil }
            if p.string(.role, of: h) == "AXLayoutItem",
               p.string(.description, of: h)?.lowercased() == named.lowercased() { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.windows().compactMap { rec($0, 0) }.first
    }

    private func dump(_ p: SystemAXProvider, _ h: AXHandle, depth: Int, maxDepth: Int) {
        let pad = String(repeating: "  ", count: depth)
        var line = p.string(.role, of: h) ?? "?"
        for a in [AXAttr.subrole, .description, .title, .value] {
            if let v = p.string(a, of: h), !v.isEmpty { line += " \(a)=\(v.prefix(48).debugDescription)" }
        }
        line += " settable=\(p.isSettable(h))"
        print(pad + line)
        guard depth < maxDepth else { return }
        for c in p.children(of: h) { dump(p, c, depth: depth + 1, maxDepth: maxDepth) }
    }
}
```

- [ ] **Step 3: Register the subcommand** (`Sources/logic-mcp/Main.swift:11`)

Change the `subcommands:` array to include `AXDump.self`:

```swift
        subcommands: [Serve.self, Capture.self, Probe.self, Calibrate.self, LCDProbe.self, AXDump.self],
```

- [ ] **Step 4: Build**

Run: `perl -e 'alarm 600; exec @ARGV' swift build`
Expected: builds clean, no warnings.

- [ ] **Step 5: Capture fixtures from real Logic** (manual; Logic open, Mixer visible)

```bash
.build/debug/logic-mcp axdump strip vox   > Tests/LogicMCPCoreTests/Fixtures/ax/mixer_strip.txt
.build/debug/logic-mcp axdump send vox    > Tests/LogicMCPCoreTests/Fixtures/ax/send_page.txt
# In Logic: click the EQ/plugin slot on 'vox' to open the Channel EQ window, then:
.build/debug/logic-mcp axdump plugin vox 0 > Tests/LogicMCPCoreTests/Fixtures/ax/plugin_window.txt
```

Read all three. **Record in the task notes** (for Tasks 9–10): the exact `description`/`title`
strings and `settable` flags for (a) the send row/level control, (b) the plugin window's
parameter value controls. If a control shows `settable=false` and exposes no
`AXIncrement`, note it — that tool will return a structured "not accessible" error for that case.

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicMCPCore/AX/SystemAXProvider.swift Sources/logic-mcp/AXDump.swift Sources/logic-mcp/Main.swift Tests/LogicMCPCoreTests/Fixtures/ax/
git commit -m "feat(ax): SystemAXProvider and axdump CLI; capture real-Logic fixtures"
```

---

## Task 3: `AXBridge` — locate mixer, find strip by name, read strip controls

**Files:**
- Create: `Sources/LogicMCPCore/AX/AXBridge.swift`
- Create: `Sources/LogicMCPCore/AX/AXStrip.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (add `ax`, inject provider)
- Test: `Tests/LogicMCPCoreTests/AXBridgeTests.swift` (replace the sanity file's contents), `AXStripTests.swift`

**Interfaces:**
- Consumes: `AXProvider`, `AXHandle`, `AXAttr`, `AXAction`, `TrackState`, `ProjectModel`, `ToolFailure`.
- Produces:
  - `struct AXStripControls: Sendable { var name; var volumeDB: Double?; var volumeSilent: Bool; var pan: Int?; var mute: Bool; var solo: Bool; var output: String? }`
  - `enum AXStrip { static func parseDB(_ title: String) -> (db: Double?, silent: Bool)? }`
  - `actor AXBridge { init(provider: AXProvider); func stripHandles() throws -> [(name: String, handle: AXHandle)]; func find(_ name: String) throws -> AXHandle; func read(_ h: AXHandle) -> AXStripControls; func control(_ h: AXHandle, description: String) -> AXHandle?; func descendant(of: AXHandle, role: String?, description: String?) -> AXHandle?; func press(_ h: AXHandle) throws; func setValue(_ v: Double, of h: AXHandle) throws; func value(of h: AXHandle) -> Double?; func isSettable(_ h: AXHandle) -> Bool; func minMax(of h: AXHandle) -> (Double?, Double?); func nudgeToRaw(_ h: AXHandle, target: Double, maxSteps: Int) throws -> Double; func titleOfLevel(_ strip: AXHandle) -> String? }`

**CRITICAL runtime fact (from `.superpowers/sdd/ax-findings.md`, verified on real Logic):**
`AXUIElementSetAttributeValue` on Logic's sliders is a **±1 nudge toward the target, NOT an
absolute set.** Every value-setting tool must therefore CONVERGE by repeated nudging, reading
an oracle each step. `nudgeToRaw` is that loop for raw-valued targets (pan, plugin params);
`set_volume` uses a dB-oracle variant. Read `ax-findings.md` before Tasks 3/6/7/10 — it
supersedes any absolute-set code shown in the original plan.

- [ ] **Step 1: Write the dB-parse test** (`Tests/LogicMCPCoreTests/AXStripTests.swift`)

```swift
import XCTest
@testable import LogicMCPCore

final class AXStripTests: XCTestCase {
    func testParsesPositiveAndNegativeDB() {
        XCTAssertEqual(AXStrip.parseDB("volume fader level, 0.0 dB")?.db, 0.0)
        XCTAssertEqual(AXStrip.parseDB("volume fader level, -6.0 dB")?.db, -6.0)
        XCTAssertEqual(AXStrip.parseDB("volume fader level, +3.5 dB")?.db, 3.5)
    }
    func testParsesSilence() {
        let r = AXStrip.parseDB("volume fader level, -∞ dB")
        XCTAssertNotNil(r); XCTAssertNil(r?.db); XCTAssertEqual(r?.silent, true)
    }
    func testRejectsUnrelated() {
        XCTAssertNil(AXStrip.parseDB("peak level meter"))
    }
}
```

- [ ] **Step 2: Run it — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXStripTests`
Expected: FAIL — `cannot find 'AXStrip' in scope`.

- [ ] **Step 3: Write `AXStrip`** (`Sources/LogicMCPCore/AX/AXStrip.swift`)

```swift
import Foundation

public struct AXStripControls: Sendable {
    public var name: String
    public var volumeDB: Double?
    public var volumeSilent: Bool
    public var pan: Int?
    public var mute: Bool
    public var solo: Bool
    public var output: String?
}

public enum AXStrip {
    /// Parse Logic's fader-level title, e.g. "volume fader level, -6.0 dB". Returns nil if
    /// the string is not a fader-level title. `db == nil && silent == true` means -∞.
    /// NOTE: confirm the exact silence glyph against `Fixtures/ax/mixer_strip.txt` (Task 2);
    /// Logic renders it "-∞ dB". Accept "-∞", "-inf", or the word "Off" to be safe.
    public static func parseDB(_ title: String) -> (db: Double?, silent: Bool)? {
        guard title.lowercased().contains("db") || title.contains("∞") else { return nil }
        guard title.lowercased().contains("volume fader level") || title.contains("∞") else {
            // Only fader-level titles carry ", N dB"; guard against "peak level meter" etc.
            if !title.lowercased().contains("fader level") { return nil }
        }
        if title.contains("∞") || title.lowercased().contains("-inf") { return (nil, true) }
        // Grab the number just before "dB".
        let scanner = Scanner(string: title)
        let allowed = CharacterSet(charactersIn: "+-0123456789.")
        _ = scanner.scanUpToCharacters(from: allowed)
        guard let n = scanner.scanDouble() else { return nil }
        return (n, false)
    }
}
```

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXStripTests`
Expected: PASS.

- [ ] **Step 5: Write the bridge test** (`Tests/LogicMCPCoreTests/AXBridgeTests.swift` — REPLACE the Task 1 sanity file with this; keep `makeMixer()`-style builders here)

```swift
import XCTest
@testable import LogicMCPCore

final class AXBridgeTests: XCTestCase {
    /// Two strips so name-matching and ambiguity are exercised.
    func provider() -> FakeAXProvider {
        func strip(_ name: String, dbTitle: String, muted: String = "off", pan: Double = 0) -> FakeAXNode {
            FakeAXNode(role: "AXLayoutItem", description: name, children: [
                FakeAXNode(role: "AXTextField", description: "name", stringValue: name),
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: muted),
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
                FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true),
                FakeAXNode(role: "AXStaticText", description: "volume fader level", title: dbTitle),
                FakeAXNode(role: "AXSlider", description: "pan", value: pan, settable: true),
                FakeAXNode(role: "AXButton", description: "Bus 9"),
            ])
        }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            strip("vox", dbTitle: "volume fader level, 0.0 dB"),
            strip("bass", dbTitle: "volume fader level, -6.0 dB", muted: "on", pan: 10),
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
    }

    func testStripHandlesListsNamesInOrder() async throws {
        let bridge = AXBridge(provider: provider())
        let names = try await bridge.stripHandles().map(\.name)
        XCTAssertEqual(names, ["vox", "bass"])
    }

    func testReadReturnsControls() async throws {
        let bridge = AXBridge(provider: provider())
        let h = try await bridge.find("bass")
        let c = await bridge.read(h)
        XCTAssertEqual(c.name, "bass")
        XCTAssertEqual(c.volumeDB, -6.0)
        XCTAssertEqual(c.mute, true)
        XCTAssertEqual(c.pan, 10)
        XCTAssertEqual(c.output, "Bus 9")
    }

    func testFindUnknownThrows() async throws {
        let bridge = AXBridge(provider: provider())
        do { _ = try await bridge.find("nope"); XCTFail("expected throw") }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "ax") }
    }

    func testMissingMixerThrows() async throws {
        let empty = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: []))
        let bridge = AXBridge(provider: empty)
        do { _ = try await bridge.stripHandles(); XCTFail("expected throw") }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "ax") }
    }
}
```

- [ ] **Step 6: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXBridgeTests`
Expected: FAIL — `cannot find 'AXBridge' in scope`.

- [ ] **Step 7: Write `AXBridge`** (`Sources/LogicMCPCore/AX/AXBridge.swift`)

```swift
import Foundation

/// The AX analog of `MCUSession`: locate the mixer surface and read/write channel strips
/// by full track name. All AX access is confined to this actor. NEVER activates Logic.
public actor AXBridge {
    private let p: AXProvider
    public init(provider: AXProvider) { self.p = provider }

    /// Depth-first search for the `AXLayoutArea desc="Mixer"` under any window.
    private func mixerArea() throws -> AXHandle {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 8 { return nil }
            if p.string(.role, of: h) == "AXLayoutArea", p.string(.description, of: h) == "Mixer" { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        for w in p.windows() { if let a = rec(w, 0) { return a } }
        throw ToolFailure(error: "no mixer surface", layer: "ax",
                          expected: "an open Mixer window or pane",
                          observed: "no AXLayoutArea \"Mixer\" in any window — open the Mixer (View ▸ Show Mixer)")
    }

    public func stripHandles() throws -> [(name: String, handle: AXHandle)] {
        let area = try mixerArea()
        return p.children(of: area)
            .filter { p.string(.role, of: $0) == "AXLayoutItem" }
            .compactMap { h in p.string(.description, of: h).map { (name: $0, handle: h) } }
    }

    public func find(_ name: String) throws -> AXHandle {
        let strips = try stripHandles()
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = strips.filter { $0.name.lowercased() == wanted }
        if exact.count == 1 { return exact[0].handle }
        let known = strips.map(\.name).joined(separator: ", ")
        if exact.count > 1 {
            throw ToolFailure(error: "ambiguous track name '\(name)'", layer: "ax",
                              expected: "a unique strip", observed: known)
        }
        let prefix = strips.filter { $0.name.lowercased().hasPrefix(wanted) }
        if prefix.count == 1 { return prefix[0].handle }
        throw ToolFailure(error: prefix.isEmpty ? "no track named '\(name)'" : "ambiguous track name '\(name)'",
                          layer: "ax", expected: "one of the mixer strips", observed: known)
    }

    public func control(_ strip: AXHandle, description: String) -> AXHandle? {
        p.children(of: strip).first { p.string(.description, of: $0) == description }
    }
    /// Recursive descendant search by role and/or description — used where a control lives
    /// deeper than a strip's immediate children (send groups, plugin windows).
    public func descendant(of h: AXHandle, role: String? = nil, description: String? = nil) -> AXHandle? {
        func rec(_ x: AXHandle, _ d: Int) -> AXHandle? {
            if d > 10 { return nil }
            let rOK = role == nil || p.string(.role, of: x) == role
            let dOK = description == nil || p.string(.description, of: x) == description
            if (role != nil || description != nil), rOK, dOK { return x }
            for c in p.children(of: x) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.children(of: h).lazy.compactMap { rec($0, 0) }.first
    }
    /// The output-routing button has a dynamic description (the bus name), so it is found
    /// by exclusion: the AXButton whose description is none of the fixed control labels.
    private func outputButton(_ strip: AXHandle) -> AXHandle? {
        let fixed: Set<String> = ["mute", "solo", "send button", "audio plug-in", "MIDI plug-in",
                                  "insert bar", "EQ", "group", "volume fader level", "peak level meter"]
        return p.children(of: strip).first {
            p.string(.role, of: $0) == "AXButton"
                && !(p.string(.description, of: $0).map(fixed.contains) ?? true)
        }
    }

    public func read(_ strip: AXHandle) -> AXStripControls {
        let name = p.string(.description, of: strip) ?? ""
        var db: Double?; var silent = false
        if let title = control(strip, description: "volume fader level").flatMap({ p.string(.title, of: $0) }),
           let parsed = AXStrip.parseDB(title) { db = parsed.db; silent = parsed.silent }
        let mute = (control(strip, description: "mute").flatMap { p.string(.value, of: $0) }) == "on"
        let solo = (control(strip, description: "solo").flatMap { p.string(.value, of: $0) }) == "on"
        let pan = control(strip, description: "pan").flatMap { p.number(of: $0) }.map { Int($0.rounded()) }
        let output = outputButton(strip).flatMap { p.string(.description, of: $0) }
        return AXStripControls(name: name, volumeDB: db, volumeSilent: silent,
                               pan: pan, mute: mute, solo: solo, output: output)
    }

    public func value(of h: AXHandle) -> Double? { p.number(of: h) }
    public func stringValue(_ attr: AXAttr, of h: AXHandle) -> String? { p.string(attr, of: h) }
    public func isSettable(_ h: AXHandle) -> Bool { p.isSettable(h) }
    public func setValue(_ v: Double, of h: AXHandle) throws { try p.setNumber(v, of: h) }
    public func press(_ h: AXHandle) throws { try p.perform(.press, on: h) }
    public func step(_ up: Bool, _ h: AXHandle) throws { try p.perform(up ? .increment : .decrement, on: h) }
    public func titleOfLevel(_ strip: AXHandle) -> String? {
        control(strip, description: "volume fader level").flatMap { p.string(.title, of: $0) }
    }
    public func minMax(of h: AXHandle) -> (Double?, Double?) { p.minMax(of: h) }

    /// Converge a slider on `target` by repeated nudging. AXSetValue on Logic sliders moves
    /// ONE unit toward the target per call (see ax-findings.md), so this loops until the
    /// read-back reaches `target` or stops progressing. Returns the achieved raw value.
    public func nudgeToRaw(_ h: AXHandle, target: Double, maxSteps: Int) throws -> Double {
        var last = p.number(of: h) ?? 0
        if last == target { return last }
        for _ in 0..<maxSteps {
            try p.setNumber(target, of: h)          // moves 1 toward target
            let now = p.number(of: h) ?? last
            if now == target || now == last { return now }   // reached, or stuck at a boundary
            last = now
        }
        return last
    }
}
```

- [ ] **Step 7b: Extend `AXProvider` with `minMax`, and make the fake model Logic's ±1 nudge**

The convergence primitive needs each slider's range, and the fake must reproduce the nudge
semantics discovered in the fixtures or the convergence tests would pass against unrealistic
behavior. Make these three edits:

1. `Sources/LogicMCPCore/AX/AXProvider.swift` — add to the `AXProvider` protocol:
```swift
    func minMax(of h: AXHandle) -> (Double?, Double?)
```

2. `Sources/LogicMCPCore/AX/SystemAXProvider.swift` — implement it (Task 2's file):
```swift
    public func minMax(of h: AXHandle) -> (Double?, Double?) {
        func d(_ key: String) -> Double? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(raw(h), key as CFString, &v) == .success,
                  let n = v as? NSNumber else { return nil }
            return n.doubleValue
        }
        return (d(kAXMinValueAttribute as String), d(kAXMaxValueAttribute as String))
    }
```

3. `Tests/LogicMCPCoreTests/FakeAXTree.swift` — add `minValue`/`maxValue` to `FakeAXNode`
(`init` params defaulting to `nil`), an optional `nudgeMode` to `FakeAXProvider`, and implement
`minMax` + the nudge:
```swift
    // FakeAXNode: add stored props
    let minValue: Double?
    let maxValue: Double?
    // and accept them in init(...) with defaults nil

    // FakeAXProvider: add
    /// When true, setNumber moves ±1 toward the target (models real Logic sliders); when
    /// false it sets absolutely. Default false so Task 1's tests are unchanged.
    var nudgeMode = false
    func minMax(of h: AXHandle) -> (Double?, Double?) {
        guard let n = node(h) else { return (nil, nil) }
        return (n.minValue, n.maxValue)
    }
    // and REPLACE the body of setNumber(_:of:) with:
    func setNumber(_ v: Double, of h: AXHandle) throws {
        guard let n = node(h), n.settable else { throw AXUnavailable() }
        let cur = n.numberValue ?? 0
        if nudgeMode {
            if v > cur { n.numberValue = cur + 1 } else if v < cur { n.numberValue = cur - 1 }
        } else {
            n.numberValue = v
        }
        onSetNumber?(n, n.numberValue ?? cur)   // hook sees the RESULTING value (Task 6 titles)
    }
```
The `onSetNumber` hook is added in Task 6; if you are doing Task 3 first, add the stored
property `var onSetNumber: ((FakeAXNode, Double) -> Void)?` now and this body compiles.

Task 1's `testSetNumberUpdatesSettableSlider` asserts absolute set (`setNumber(200) == 200`)
with `nudgeMode` default false — it stays green. Convergence tests (Tasks 6/7/10) set
`provider.nudgeMode = true`.

- [ ] **Step 7c: Run the extended fake/bridge tests**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXBridgeTests`
Expected: PASS (existing bridge tests unaffected — nudgeMode defaults off).

- [ ] **Step 8: Wire the bridge into `Daemon`** (`Sources/LogicMCPCore/Daemon.swift`)

Replace the top of the class and `init` with:

```swift
public final class Daemon: Sendable {
    public let session: MCUSession
    public let model: ProjectModel
    public let navigator: MixerNavigator
    public let ax: AXBridge
    public let journal = UndoJournal()

    public init(wire: MCUWire, axProvider: AXProvider) async {
        session = MCUSession(wire: wire)
        model = ProjectModel()
        navigator = MixerNavigator(session: session, model: model)
        ax = AXBridge(provider: axProvider)
        await session.start()
    }
```

(Leave `registerAllTools` unchanged for now.)

- [ ] **Step 9: Update the two `Daemon(wire:)` call sites**

`Sources/logic-mcp/Main.swift` `Serve.run()` — change to inject the system provider, degrading to a clear message if Logic/permission is absent:

```swift
        let wire = try CoreMIDIWire()
        let axProvider: AXProvider
        do { axProvider = try SystemAXProvider() }
        catch { FileHandle.standardError.write(Data("warning: Accessibility unavailable; AX mixer tools will error until Logic is running and permission is granted\n".utf8)); axProvider = try SystemAXProvider.unavailablePlaceholder() }
        let daemon = await Daemon(wire: wire, axProvider: axProvider)
```

Add to `SystemAXProvider` a placeholder that always throws `AXUnavailable` from `root()/windows()` (so tools return structured errors rather than crashing at startup):

```swift
    /// A provider that reports Logic as unavailable — used at `serve` startup when
    /// permission/Logic is missing, so tools fail gracefully instead of the daemon aborting.
    public static func unavailablePlaceholder() throws -> SystemAXProvider { Unavailable() }
    private final class Unavailable: SystemAXProvider, @unchecked Sendable {
        init() { try! super.init(neverResolves: ()) }
    }
```

(If subclassing proves awkward under the throwing init, instead make `SystemAXProvider` hold an
optional app and return empty `windows()` when nil; either way the contract is: no Logic ⇒
`stripHandles()` throws the `"no mixer surface"` `ToolFailure`. Pick whichever compiles cleanly and
note it in the commit.)

Also update the test helper used by existing `ToolTests` (search for `Daemon(wire:`):

Run: `grep -rn "Daemon(wire:" Tests Sources`
For each test call site, pass a `FakeAXProvider` (empty root is fine where AX isn't under test):
`await Daemon(wire: wire, axProvider: FakeAXProvider(root: FakeAXNode(role: "AXApplication")))`.

- [ ] **Step 10: Build and run the full suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift build && perl -e 'alarm 600; exec @ARGV' swift test`
Expected: builds; all prior tests plus `AXBridgeTests`/`AXStripTests` pass (126 + new).

- [ ] **Step 11: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/AX/AXStrip.swift Sources/LogicMCPCore/Daemon.swift Sources/logic-mcp/Main.swift Tests/LogicMCPCoreTests/AXBridgeTests.swift Tests/LogicMCPCoreTests/AXStripTests.swift
git commit -m "feat(ax): AXBridge locates mixer and reads strips by name; inject provider into Daemon"
```

---

## Task 4: `AXMixer` read → shadow model; re-home `refresh_state`/`get_project_overview`/`get_track`

**Files:**
- Create: `Sources/LogicMCPCore/AX/AXMixer.swift`
- Modify: `Sources/LogicMCPCore/Model/ProjectModel.swift` (add `output`; add `replaceTracks(_ controls:)`)
- Modify: `Sources/LogicMCPCore/Daemon.swift` (hold `axMixer`)
- Modify: `Sources/LogicMCPCore/Tools/QueryTools.swift`
- Test: `Tests/LogicMCPCoreTests/AXMixerTests.swift`

**Interfaces:**
- Consumes: `AXBridge`, `AXStripControls`, `ProjectModel`.
- Produces: `actor AXMixer { init(bridge: AXBridge, model: ProjectModel); func syncTracks() async throws -> [String] }`; `ProjectModel.replaceTracks(_ controls: [AXStripControls])`.

- [ ] **Step 1: Add `output` to `TrackState`** (`Sources/LogicMCPCore/Model/ProjectModel.swift`)

```swift
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
```

Add a controls-based populate alongside the existing `replaceTracks(_ names:)`:

```swift
    public func replaceTracks(_ controls: [AXStripControls]) {
        tracks = controls.enumerated().map { i, c in
            TrackState(index: i, name: c.name, volumeRaw: nil, volumeDB: c.volumeDB,
                       volumeIsSilent: c.volumeSilent,
                       pan: c.pan.map { $0 + 64 }, mute: c.mute, solo: c.solo, output: c.output)
        }
        staleAt = nil
    }
```

(Note: `pan` is stored 0…127 internally — hard-left 0, center 64 — matching the existing
`trackValue` which subtracts 64. AX pan `val` is signed around 0, so add 64. Confirm the AX
pan range against `Fixtures/ax/mixer_strip.txt`; adjust the `+64` if Logic reports 0…127.)

- [ ] **Step 2: Write the mixer-sync test** (`Tests/LogicMCPCoreTests/AXMixerTests.swift`)

```swift
import XCTest
@testable import LogicMCPCore

final class AXMixerTests: XCTestCase {
    func testSyncTracksPopulatesModelFromAX() async throws {
        func strip(_ name: String, db: String, mute: String, pan: Double) -> FakeAXNode {
            FakeAXNode(role: "AXLayoutItem", description: name, children: [
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: mute),
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
                FakeAXNode(role: "AXStaticText", description: "volume fader level", title: db),
                FakeAXNode(role: "AXSlider", description: "pan", value: pan, settable: true),
                FakeAXNode(role: "AXButton", description: "Bus 9"),
            ])
        }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            strip("vox", db: "volume fader level, 0.0 dB", mute: "off", pan: 0),
            strip("bass", db: "volume fader level, -6.0 dB", mute: "on", pan: 10),
        ])
        let root = FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", children: [area])])
        let model = ProjectModel()
        let mixer = AXMixer(bridge: AXBridge(provider: FakeAXProvider(root: root)), model: model)

        let names = try await mixer.syncTracks()
        XCTAssertEqual(names, ["vox", "bass"])
        let snap = await model.snapshot
        XCTAssertNil(snap.staleAt)
        XCTAssertEqual(snap.tracks[1].name, "bass")
        XCTAssertEqual(snap.tracks[1].volumeDB, -6.0)
        XCTAssertEqual(snap.tracks[1].mute, true)
        XCTAssertEqual(snap.tracks[1].pan, 74)     // 10 + 64
    }
}
```

- [ ] **Step 3: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixerTests`
Expected: FAIL — `cannot find 'AXMixer' in scope`.

- [ ] **Step 4: Write `AXMixer`** (`Sources/LogicMCPCore/AX/AXMixer.swift`)

```swift
import Foundation

/// Reads the whole mixer into the shadow `ProjectModel` in one pass. No banking, no
/// truncation, no overlap geometry — AX addresses every strip regardless of visible bank.
public actor AXMixer {
    private let bridge: AXBridge
    private let model: ProjectModel
    public init(bridge: AXBridge, model: ProjectModel) {
        self.bridge = bridge; self.model = model
    }

    @discardableResult
    public func syncTracks() async throws -> [String] {
        let handles = try await bridge.stripHandles()
        var controls: [AXStripControls] = []
        for h in handles { controls.append(await bridge.read(h.handle)) }
        await model.replaceTracks(controls)
        return controls.map(\.name)
    }
}
```

- [ ] **Step 5: Hold `axMixer` on `Daemon`** (`Sources/LogicMCPCore/Daemon.swift`)

In the class add `public let axMixer: AXMixer` and in `init`, after `ax = …`:
```swift
        axMixer = AXMixer(bridge: ax, model: model)
```

- [ ] **Step 6: Re-home the query tools** (`Sources/LogicMCPCore/Tools/QueryTools.swift`)

Change the three tools to read via AX. `RefreshStateTool.invoke`:
```swift
    public func invoke(_ args: [String: Value]) async throws -> Value {
        _ = try await daemon.axMixer.syncTracks()
        return await overviewValue(daemon.model.snapshot)
    }
```
`GetProjectOverviewTool.invoke`:
```swift
    public func invoke(_ args: [String: Value]) async throws -> Value {
        if await daemon.model.snapshot.staleAt != nil {
            _ = try? await daemon.axMixer.syncTracks()
        }
        return await overviewValue(daemon.model.snapshot)
    }
```
`GetTrackTool.invoke` — resolve after ensuring fresh state:
```swift
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        if await daemon.model.snapshot.staleAt != nil { _ = try? await daemon.axMixer.syncTracks() }
        return trackValue(try await daemon.model.track(named: name))
    }
```
Update each tool's `description` string, replacing "over the MCU wire" with "via Accessibility".
Also extend `trackValue` to surface routing:
```swift
        "output": t.output.map { Value.string($0) } ?? .null,
```

- [ ] **Step 7: Run the suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift build && perl -e 'alarm 600; exec @ARGV' swift test`
Expected: PASS, including `AXMixerTests`. Fix any `ToolTests` that asserted the old MCU-sourced overview shape (they now get AX-sourced state; where a test used the MCU `FakeLogic` to seed tracks, seed the `FakeAXProvider` instead or assert `stale`).

- [ ] **Step 8: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXMixer.swift Sources/LogicMCPCore/Model/ProjectModel.swift Sources/LogicMCPCore/Daemon.swift Sources/LogicMCPCore/Tools/QueryTools.swift Tests/LogicMCPCoreTests/AXMixerTests.swift
git commit -m "feat(ax): AXMixer syncs full mixer into shadow model; query tools read via AX"
```

---

## Task 5: `set_mute` / `set_solo` via AX

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/MixTools.swift` (`SetMuteTool`, `SetSoloTool`, `setToggle`)
- Test: `Tests/LogicMCPCoreTests/AXMixToolTests.swift`

**Interfaces:**
- Consumes: `AXBridge.find/read/control/press`, `ProjectModel.updateTrack`, `UndoJournal`.
- Produces: an AX-based `setToggleAX(_ daemon:trackName:on:isMute:) async throws -> Value`.

- [ ] **Step 1: Write the test** (`Tests/LogicMCPCoreTests/AXMixToolTests.swift`)

```swift
import XCTest
import MCP
@testable import LogicMCPCore

final class AXMixToolTests: XCTestCase {
    func daemon(_ provider: FakeAXProvider) async -> Daemon {
        await Daemon(wire: InMemoryWire(), axProvider: provider)
    }
    func oneStrip(mute: String = "off") -> FakeAXProvider {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: mute),
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
            FakeAXNode(role: "AXStaticText", description: "volume fader level", title: "volume fader level, 0.0 dB"),
            FakeAXNode(role: "AXSlider", description: "pan", value: 0, settable: true, minValue: -64, maxValue: 63),
            FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true, minValue: 0, maxValue: 233),
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", children: [area])]))
        p.nudgeMode = true   // model real Logic: AXSetValue nudges ±1 toward target
        return p
    }

    func testMuteOnPressesAndVerifies() async throws {
        let d = await daemon(oneStrip(mute: "off"))
        _ = try await d.axMixer.syncTracks()
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
        XCTAssertEqual(await d.model.snapshot.tracks[0].mute, true)
    }

    func testMuteIdempotentWhenAlreadyOn() async throws {
        let d = await daemon(oneStrip(mute: "on"))
        _ = try await d.axMixer.syncTracks()
        // Already on: pressing would turn it OFF, so an idempotent impl must NOT press.
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
    }
}
```

- [ ] **Step 2: Run — fails** (compile error: `Daemon(wire:axProvider:)` already exists, but `SetMuteTool` still calls MCU `setToggle`; the idempotent test will fail because the MCU path ignores the AX provider)

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: FAIL.

- [ ] **Step 3: Add the AX toggle and switch the tools** (`Sources/LogicMCPCore/Tools/MixTools.swift`)

Add:
```swift
/// Mute/solo via AX: read the switch's value, press only if it differs, verify by re-read.
/// Idempotent by construction. No focus, no MCU.
func setToggleAX(_ daemon: Daemon, trackName: String, on: Bool, isMute: Bool) async throws -> Value {
    let label = isMute ? "mute" : "solo"
    let strip = try await daemon.ax.find(trackName)
    let priorControls = await daemon.ax.read(strip)
    let prior = isMute ? priorControls.mute : priorControls.solo
    guard let button = await daemon.ax.control(strip, description: label) else {
        throw ToolFailure(error: "no \(label) control", layer: "ax",
                          expected: "a \(label) button on '\(trackName)'", observed: "none")
    }
    let current = await daemon.ax.stringValue(.value, of: button) == "on"
    if current != on {
        try await daemon.ax.press(button)
        let after = await daemon.ax.stringValue(.value, of: button) == "on"
        guard after == on else {
            throw ToolFailure(error: "\(label) not confirmed", layer: "ax",
                              expected: "\(label) \(on)", observed: "\(after)")
        }
    }
    let name = priorControls.name
    await daemon.journal.record(MixMutation(
        tool: isMute ? "set_mute" : "set_solo", track: name,
        undoArguments: ["track": name, "on": prior ? "true" : "false"],
        descriptionText: "\(name) \(label) \(prior) → \(on)"))
    if let idx = await daemon.model.indexOf(name) {
        await daemon.model.updateTrack(index: idx) { if isMute { $0.mute = on } else { $0.solo = on } }
    }
    return .object(["track": .string(name), Value.Key(stringLiteral: label): .bool(on)])
}
```
(If `Value.Key` is not how this SDK keys objects, use the same `.object([label: .bool(on)])`
dictionary-literal form already used elsewhere in this file — `label` is a `String`.)

Add `ProjectModel.indexOf` (`Model/ProjectModel.swift`):
```swift
    public func indexOf(_ name: String) -> Int? { tracks.firstIndex { $0.name == name } }
```

Switch the tools to call it:
```swift
// in SetMuteTool.invoke:
        return try await setToggleAX(daemon, trackName: trackName, on: on, isMute: true)
// in SetSoloTool.invoke:
        return try await setToggleAX(daemon, trackName: trackName, on: on, isMute: false)
```
Update both tools' `description` (drop "mute-LED echo"; say "verified by re-reading the AX switch").

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/MixTools.swift Sources/LogicMCPCore/Model/ProjectModel.swift Tests/LogicMCPCoreTests/AXMixToolTests.swift
git commit -m "feat(ax): set_mute/set_solo via AX (press-if-different, re-read verify)"
```

---

## Task 6: `set_volume` via AX (curve-free, dB-title oracle)

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/MixTools.swift` (`SetVolumeTool`)
- Test: `Tests/LogicMCPCoreTests/AXMixToolTests.swift` (add cases)

**Interfaces:**
- Consumes: `AXBridge.find/control/value/isSettable/setValue/step/titleOfLevel`, `AXStrip.parseDB`.
- Produces: `func axSetVolume(_ daemon:strip:targetDB:) async throws -> Double` (returns achieved dB).

**Algorithm (no fader curve):** the exact dB is the fader-level *title*. Binary-search the
volume slider's unit value using the title as the monotonic oracle: read current dB; if the
slider is settable, bracket the unit value and bisect until |dB − target| ≤ 0.1 or the
bracket collapses; if not settable, step with `AXIncrement`/`AXDecrement` toward target,
stopping when it overshoots or stops improving. Return the dB Logic actually shows.

- [ ] **Step 1: Add tests** (append to `AXMixToolTests.swift`)

```swift
    /// A fake volume slider whose fader-level title tracks a monotonic unit→dB curve, so
    /// binary search has something real to converge on.
    // NUDGE-MODE fake: models real Logic (AXSetValue moves ±1 toward target). The dB title is
    // recomputed from the fader unit after every nudge, so the convergence loop has a moving
    // oracle exactly like real Logic. dB = (unit - 173) * 0.1 (173 ≈ 0 dB; matches fixtures).
    func stripWithVolumeCurve() -> FakeAXProvider {
        let level = FakeAXNode(role: "AXStaticText", description: "volume fader level",
                               title: "volume fader level, 0.0 dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173,
                             settable: true, minValue: 0, maxValue: 233)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            vol, level,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                               children: [FakeAXNode(role: "AXWindow", children: [area])]))
        p.nudgeMode = true   // <-- model Logic's ±1-per-set behavior
        p.onSetNumber = { node, resulting in
            guard node === vol else { return }
            let db = (resulting - 173) * 0.1
            level.title = "volume fader level, \(String(format: "%+.1f", db)) dB"
        }
        return p
    }

    func testSetVolumeConvergesToTargetDB() async throws {
        let d = await daemon(stripWithVolumeCurve())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "db": .double(-6.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -6.0, accuracy: 0.11)
        XCTAssertEqual(o["source"], .string("ax"))
    }

    func testSetVolumeDeltaFromCurrent() async throws {
        let d = await daemon(stripWithVolumeCurve())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetVolumeTool(daemon: d).invoke(["track": .string("vox"), "delta": .double(-3.0)])
        guard case .object(let o) = result, case .double(let db)? = o["volumeDB"] else { return XCTFail() }
        XCTAssertEqual(db, -3.0, accuracy: 0.11)
    }
```

The `onSetNumber` hook and the nudge-aware `setNumber` were added to `FakeAXProvider` in Task 3
(Step 7b). If for some reason they are absent, add `var onSetNumber: ((FakeAXNode, Double) -> Void)?`
and the nudge `setNumber` body from Task 3 Step 7b now. Do not re-add them if present.

- [ ] **Step 2: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: FAIL (`SetVolumeTool` still MCU; `source` is `logic`/`curve`, not `ax`).

- [ ] **Step 3: Rewrite `SetVolumeTool`** (`Sources/LogicMCPCore/Tools/MixTools.swift`)

Keep the existing argument parsing (db XOR delta) verbatim. Replace everything from
`let (track, channel) = try await resolveAndBank(...)` to the end of `invoke` with:

```swift
        let strip = try await daemon.ax.find(trackName)
        guard let vol = await daemon.ax.control(strip, description: "volume fader") else {
            throw ToolFailure(error: "no volume fader", layer: "ax",
                              expected: "a volume slider on '\(trackName)'", observed: "none")
        }
        func currentDB() async -> Double? {
            guard let title = await daemon.ax.titleOfLevel(strip),
                  let parsed = AXStrip.parseDB(title) else { return nil }
            return parsed.db
        }
        let startDB = await currentDB()
        let targetDB: Double
        if let db { targetDB = db }
        else {
            guard let s = startDB else {
                throw ToolFailure(error: "current volume unknown; cannot apply delta", layer: "ax",
                                  expected: "a readable fader level for '\(trackName)'", observed: "none")
            }
            targetDB = s + delta!
        }
        let achieved = try await axConvergeVolume(daemon, strip: strip, slider: vol, targetDB: targetDB)
        let name = await daemon.ax.read(strip).name
        if let idx = await daemon.model.indexOf(name) {
            await daemon.model.updateTrack(index: idx) {
                $0.volumeDB = achieved; $0.volumeIsSilent = (achieved == nil)
            }
        }
        await daemon.journal.record(MixMutation(
            tool: "set_volume", track: name,
            undoArguments: startDB.map { ["track": name, "db": String($0)] },
            descriptionText: "\(name) volume \(startDB.map { String($0) } ?? "-∞") → \(achieved.map { String($0) } ?? "-∞") dB"))
        return .object([
            "track": .string(name),
            "volumeDB": achieved.map { Value.double($0) } ?? .null,
            "source": .string("ax"),
        ])
    }
}

/// Converge the fader on `targetDB` using the dB title as the oracle. No curve. Returns the
/// dB Logic actually renders (nil ⇒ silent). Because AXSetValue NUDGES ±1 toward the passed
/// value (ax-findings.md), we drive the slider toward its max to go up and toward its min to
/// go down, one nudge per loop, re-reading the dB title each time until within tolerance or
/// stuck. This is curve-free and correct against real Logic's relative-set behavior.
func axConvergeVolume(_ daemon: Daemon, strip: AXHandle, slider: AXHandle, targetDB: Double) async throws -> Double? {
    func db() async -> Double? {
        guard let t = await daemon.ax.titleOfLevel(strip) else { return nil }
        return AXStrip.parseDB(t)?.db
    }
    let (loOpt, hiOpt) = await daemon.ax.minMax(of: slider)
    let lo = loOpt ?? 0, hi = hiOpt ?? 233
    var last = await db()
    for _ in 0..<400 {
        guard let cur = await db() else { break }              // silent/unreadable
        if abs(cur - targetDB) <= 0.1 { return cur }
        try await daemon.ax.setValue(cur < targetDB ? hi : lo, of: slider)   // one nudge toward target
        let now = await db()
        if now == nil { return cur }
        if now == last { return now }                          // stuck (boundary/target)
        last = now
    }
    return await db()
}
```

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: PASS (convergence within 0.11 dB).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/MixTools.swift Tests/LogicMCPCoreTests/FakeAXTree.swift Tests/LogicMCPCoreTests/AXMixToolTests.swift
git commit -m "feat(ax): set_volume via AX with curve-free dB-title convergence"
```

---

## Task 7: `set_pan` via AX (direct value write)

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/MixTools.swift` (`SetPanTool`)
- Test: `Tests/LogicMCPCoreTests/AXMixToolTests.swift` (add cases)

**Interfaces:**
- Consumes: `AXBridge.find/control/setValue/value`. Produces: none new.

- [ ] **Step 1: Add tests**

```swift
    func testSetPanWritesAndReadsBack() async throws {
        let d = await daemon(oneStrip())
        _ = try await d.axMixer.syncTracks()
        let result = try await SetPanTool(daemon: d).invoke(["track": .string("vox"), "position": .int(-30)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["pan"], .int(-30))
        XCTAssertEqual(o["source"], .string("ax"))
        XCTAssertEqual(await d.model.snapshot.tracks[0].pan, 34)   // -30 + 64
    }
```

- [ ] **Step 2: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: FAIL (still MCU pan).

- [ ] **Step 3: Rewrite `SetPanTool.invoke`** (keep the `-64…63` arg validation verbatim; replace the body after it)

```swift
        let strip = try await daemon.ax.find(trackName)
        guard let pan = await daemon.ax.control(strip, description: "pan") else {
            throw ToolFailure(error: "no pan control", layer: "ax",
                              expected: "a pan slider on '\(trackName)'", observed: "none")
        }
        guard await daemon.ax.isSettable(pan) else {
            throw ToolFailure(error: "pan not settable via AX", layer: "ax",
                              expected: "a settable pan slider", observed: "read-only")
        }
        // AX pan range is −64…63 (matches the tool's `position`); AXSetValue nudges ±1 per call
        // (ax-findings.md), so converge with nudgeToRaw. 128 steps covers the full range.
        let observedRaw = try await daemon.ax.nudgeToRaw(pan, target: Double(position), maxSteps: 128)
        let observed = Int(observedRaw.rounded())
        let name = await daemon.ax.read(strip).name
        let priorPan = await daemon.model.snapshot.tracks.first { $0.name == name }?.pan
        if let idx = await daemon.model.indexOf(name) {
            await daemon.model.updateTrack(index: idx) { $0.pan = observed + 64 }
        }
        await daemon.journal.record(MixMutation(
            tool: "set_pan", track: name,
            undoArguments: priorPan.map { ["track": name, "position": String($0 - 64)] },
            descriptionText: "\(name) pan \(priorPan.map { String($0 - 64) } ?? "?") → \(observed)"))
        return .object(["track": .string(name), "pan": .int(observed), "source": .string("ax")])
    }
}
```

(**Confirm the AX pan unit** against `Fixtures/ax/mixer_strip.txt`: this assumes Logic's pan
`val` is signed −64…63. If Logic reports 0…127 or −1.0…1.0, scale here and in
`replaceTracks`. The fixture from Task 2 is authoritative.)

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/MixTools.swift Tests/LogicMCPCoreTests/AXMixToolTests.swift
git commit -m "feat(ax): set_pan via direct AX value write with read-back verify"
```

---

## Task 8: Deadline `MCUSession.settle()` (MCU demotion, safety)

**Files:**
- Modify: `Sources/LogicMCPCore/MCU/MCUSession.swift:123`
- Test: `Tests/LogicMCPCoreTests/MCUSessionTests.swift` (add a case)

**Interfaces:** `settle(_ quiet:overall:)` — add an overall deadline, default preserves old callers.

- [ ] **Step 1: Add a test** proving `settle` returns even under a never-quiet event stream.

```swift
    func testSettleReturnsUnderContinuousTraffic() async throws {
        let wire = InMemoryWire()
        let session = MCUSession(wire: wire)
        await session.start()
        // Flood meter events so the quiet window never opens.
        let flood = Task {
            for _ in 0..<10_000 { await wire.deliver(MCUCodec.encode(MCUEvent.meter(channel: 0, level: 5))); try? await Task.sleep(for: .milliseconds(1)) }
        }
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await session.settle(.milliseconds(50), overall: .milliseconds(300)) }
        flood.cancel()
        XCTAssertLessThan(elapsed, .milliseconds(600))   // bounded by the overall deadline
    }
```
(If `InMemoryWire` lacks a `deliver`, use the existing mechanism the other MCU tests use to
inject inbound packets — grep `MCUSessionTests` for the pattern and match it.)

- [ ] **Step 2: Run — fails** (no `overall:` parameter)

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter MCUSessionTests`
Expected: FAIL — extra argument `overall`.

- [ ] **Step 3: Deadline `settle`** (`Sources/LogicMCPCore/MCU/MCUSession.swift:123`)

```swift
    /// Wait for a `quiet`-long gap with no inbound events, but never longer than `overall`.
    /// Logic streams meter/timecode messages continuously while the transport rolls, so the
    /// quiet window may never open during playback; the overall deadline guarantees return.
    public func settle(_ quiet: Duration, overall: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + overall
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            let window = min(quiet, remaining)
            if await waitFor(timeout: window, { _ in true }) == nil { return }   // quiet gap reached
        }
    }
```

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter MCUSessionTests`
Expected: PASS. Then run the whole suite to be sure no caller regressed:
`pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/MCU/MCUSession.swift Tests/LogicMCPCoreTests/MCUSessionTests.swift
git commit -m "fix(mcu): deadline settle() so playback meter traffic cannot hang it"
```

---

## Task 9: `set_send` via AX (uses Task 2 fixtures) + disable the broken MCU send path

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/SendTools.swift`
- Test: `Tests/LogicMCPCoreTests/AXMixToolTests.swift` (add cases)
- Reference: `Tests/LogicMCPCoreTests/Fixtures/ax/send_page.txt`

**Read the fixture first.** `send_page.txt` shows how a strip's send is represented — the
control's `description`, whether the level is a settable slider, a value in a title, or only
reachable by opening a menu. Build the fake and the selector to match what the fixture shows.
The pseudo-selectors below assume the common Logic layout: a strip has send slot buttons
(`description` = the destination bus, e.g. "Bus 3"/"Aux 1") and, with "Sends on Faders" or via
the send's own control, a settable level. **Adjust names to the fixture.**

**Interfaces:** `SetSendTool.invoke` reads AX only; no MCU. Produces nothing new.

- [ ] **Step 1: Add a test** (fake mirrors the fixture; here we assume a settable send-level slider tagged by destination)

```swift
    func stripWithSend(_ level: Double = 0) -> FakeAXProvider {
        // Adjust roles/descriptions to Fixtures/ax/send_page.txt.
        let sendLevel = FakeAXNode(role: "AXSlider", description: "Aux 1", value: level, settable: true)
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            sendLevel,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", children: [area])]))
    }

    func testSetSendWritesLevel() async throws {
        let d = await daemon(stripWithSend())
        _ = try await d.axMixer.syncTracks()
        let r = try await SetSendTool(daemon: d).invoke([
            "track": .string("vox"), "bus": .string("Aux 1"), "level": .int(90)])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["level"], .int(90))
    }

    func testSetSendUnknownBusErrors() async throws {
        let d = await daemon(stripWithSend())
        _ = try await d.axMixer.syncTracks()
        do { _ = try await SetSendTool(daemon: d).invoke([
                "track": .string("vox"), "bus": .string("Nope"), "level": .int(10)])
             XCTFail("expected throw") }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "ax") }
    }
```

- [ ] **Step 2: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: FAIL (still MCU send).

- [ ] **Step 3: Rewrite `SetSendTool.invoke`** (replace the MCU body; keep the `level` 0…127 validation). Selector names per the fixture:

```swift
        let strip = try await daemon.ax.find(trackName)
        // Find the send control addressed to `bus`: a direct child, else a deeper descendant
        // (send group). `descendant` was added to AXBridge in Task 3.
        let sendControl = await daemon.ax.control(strip, description: bus)
            ?? (await daemon.ax.descendant(of: strip, description: bus))
        guard let send = sendControl, await daemon.ax.isSettable(send) else {
            throw ToolFailure(error: "send level for '\(bus)' not accessible via AX", layer: "ax",
                              expected: "a settable send to '\(bus)' on '\(trackName)'",
                              observed: "no matching settable control")
        }
        try await daemon.ax.setValue(Double(level), of: send)
        guard let echoed = await daemon.ax.value(of: send).map({ Int($0.rounded()) }) else {
            throw ToolFailure(error: "send level not confirmed", layer: "ax",
                              expected: "a numeric send level", observed: "unreadable")
        }
        let name = await daemon.ax.read(strip).name
        await daemon.journal.record(MixMutation(
            tool: "set_send", track: name, undoArguments: nil,
            descriptionText: "\(name) send \(bus) → \(echoed)"))
        return .object(["track": .string(name), "bus": .string(bus), "level": .int(echoed)])
```

**Note:** the `control(strip, description: bus)` lookup only finds a DIRECT child by exact
description. If the fixture shows the level lives one level deeper (e.g. inside a send group),
add a small recursive finder on `AXBridge` (`func descendant(_ h:, description:) -> AXHandle?`)
and use it. Do NOT keep the placeholder `?? … nil` line — it is only there to show where the
lookup goes; replace with the real finder that compiles. Remove the entire old MCU send body.

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMixToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/SendTools.swift Tests/LogicMCPCoreTests/AXMixToolTests.swift
git commit -m "feat(ax): set_send via AX; retire the wrong-track MCU send path"
```

---

## Task 10: `get_plugin_params` / `set_plugin_param` via AX; disable the dangerous MCU path

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift`
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `descendant(_:role:description:)` + a window finder)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`
- Reference: `Tests/LogicMCPCoreTests/Fixtures/ax/plugin_window.txt`

**Read `plugin_window.txt` first.** It shows the plugin window's control tree — the roles and
descriptions of parameter controls, whether their values are readable (title/value) and
settable. Two outcomes:
- **Addressable** (stock Channel EQ almost certainly is): implement read/write against those
  controls.
- **Opaque** (some third-party AUs): the tool returns a structured "parameters not accessible"
  error for that plugin. Never fabricate.

This task also **disables the old MCU plugin path** (`enterPluginEdit`/`exitPluginEdit` and the
`.assignPlugin`/`.vpotPress` sequence): the code stays in the file but the tools no longer call
it, so the intermittent wrong-track read/write cannot recur.

**Interfaces:**
- Consumes: `AXBridge.descendant(of:role:description:)` (added in Task 3).
- Produces on `AXBridge`:
  - `func pluginWindow(titled fragment: String) -> AXHandle?` (find an `AXWindow` whose title contains the plugin/track name)
  - `func openPlugin(_ strip: AXHandle, slot: Int) throws` (AXPress the `"audio plug-in"` / `"EQ"` control; NOTE this may open a window — acceptable, it does not require focus)

- [ ] **Step 1: Write tests** (`Tests/LogicMCPCoreTests/AXPluginToolTests.swift`) modelling the fixture. Assume the fixture shows parameter controls as `AXSlider`/`AXValueIndicator` with a `description` (param name) and a settable value.

```swift
import XCTest
import MCP
@testable import LogicMCPCore

final class AXPluginToolTests: XCTestCase {
    /// Mixer with a 'vox' strip whose EQ, when "opened", exposes a plugin window with two params.
    func makeProvider() -> FakeAXProvider {
        // Plugin window (already open), titled by TRACK name, with a close button + settable
        // sliders carrying real ranges — mirrors Fixtures/ax/plugin_window.txt.
        let gain = FakeAXNode(role: "AXSlider", description: "Gain", title: "0.0 dB",
                              value: 240, settable: true, minValue: 0, maxValue: 480)
        let freq = FakeAXNode(role: "AXSlider", description: "Peak 1 Frequency", title: "1000 Hz",
                              value: 250, settable: true, minValue: 0, maxValue: 1050)
        let pluginWindow = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"), gain, freq,
        ])
        // Strip carries a plugin GROUP "Channel EQ" with an "open" child (slot 0).
        let eqGroup = FakeAXNode(role: "AXGroup", description: "Channel EQ", children: [
            FakeAXNode(role: "AXCheckBox", description: "bypass", stringValue: "0"),
            FakeAXNode(role: "AXButton", description: "open"),
        ])
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            eqGroup,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
            children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area]), pluginWindow]))
        p.nudgeMode = true
        return p
    }

    func testGetPluginParamsListsNames() async throws {
        let d = await Daemon(wire: InMemoryWire(), axProvider: makeProvider())
        _ = try await d.axMixer.syncTracks()
        let r = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
        guard case .object(let o) = r, case .array(let params)? = o["params"] else { return XCTFail() }
        XCTAssertEqual(params.count, 2)
    }

    func testSetPluginParamWritesAndVerifies() async throws {
        let d = await Daemon(wire: InMemoryWire(), axProvider: makeProvider())
        _ = try await d.axMixer.syncTracks()
        let r = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Gain"), "value": .double(1.0)])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["param"], .string("Gain"))
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: FAIL.

- [ ] **Step 3: Add the AX finders** (`Sources/LogicMCPCore/AX/AXBridge.swift`)

```swift
    // `descendant(of:role:description:)` was added to AXBridge in Task 3 — reuse it here.

    /// Plugin slots on a strip are AXGroups (e.g. "Channel EQ", "RetroSyn") each with an
    /// "open" child button (see Fixtures/ax/mixer_strip.txt). Returns them in tree order so
    /// `slot` indexes them; the dedicated Channel EQ group is included like any other.
    public func pluginGroups(_ strip: AXHandle) -> [(name: String, group: AXHandle)] {
        p.children(of: strip).compactMap { g in
            guard p.string(.role, of: g) == "AXGroup",
                  let name = p.string(.description, of: g), !name.isEmpty,
                  p.children(of: g).contains(where: { p.string(.description, of: $0) == "open" })
            else { return nil }
            return (name, g)
        }
    }
    /// A plugin window is an AXWindow whose title is the TRACK name and which contains
    /// parameter sliders (distinguishes it from the mixer window, also track-titled sometimes).
    public func pluginWindow(track: String) -> AXHandle? {
        p.windows().first {
            (p.string(.title, of: $0) ?? "") == track
                && descendant(of: $0, role: "AXSlider", description: nil) != nil
                && descendant(of: $0, role: nil, description: "close") != nil
        }
    }
    /// The plugin's parameter controls: settable AXSliders only, DEDUPED by description
    /// (Logic exposes duplicates like "Gain" ×3 — keep the first settable slider per name).
    public func paramControls(in window: AXHandle) -> [(name: String, handle: AXHandle)] {
        var out: [(String, AXHandle)] = []
        var seen = Set<String>()
        func rec(_ x: AXHandle, _ d: Int) {
            if d > 12 { return }
            if p.string(.role, of: x) == "AXSlider", p.isSettable(x),
               let name = p.string(.description, of: x), !name.isEmpty, !seen.contains(name) {
                seen.insert(name); out.append((name, x))
            }
            for c in p.children(of: x) { rec(c, d + 1) }
        }
        rec(window, 0)
        return out.map { (name: $0.0, handle: $0.1) }
    }
```

- [ ] **Step 4: Rewrite the plugin tools** (`Sources/LogicMCPCore/Tools/PluginTools.swift`)

Add an AX entry that opens the plugin and returns its param controls; **leave the old
`enterPluginEdit`/`exitPluginEdit` MCU functions in the file but unused** (a comment marks
them disabled). New helper:

```swift
/// Open (if needed) the plugin at `slot` on `track` via AX and return the plugin window's
/// parameter controls. No MCU, no track selection, no wrong-track race. Throws a structured
/// error if the strip/slot has no addressable plugin window.
func axEnterPlugin(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (name: String, window: AXHandle, params: [(name: String, handle: AXHandle)]) {
    let strip = try await daemon.ax.find(trackName)
    let name = await daemon.ax.read(strip).name
    let groups = await daemon.ax.pluginGroups(strip)
    guard slot >= 0, slot < groups.count else {
        throw ToolFailure(error: "no plugin in slot \(slot) on '\(name)'", layer: "ax",
                          expected: "one of \(groups.count) plugin slots: \(groups.map(\.name).joined(separator: ", "))",
                          observed: "slot \(slot) out of range")
    }
    // Open ONLY if the plugin window isn't already up — the "open" button toggles, so pressing
    // it on an already-open window would CLOSE it.
    if await daemon.ax.pluginWindow(track: name) == nil,
       let openBtn = await daemon.ax.descendant(of: groups[slot].group, role: "AXButton", description: "open") {
        try? await daemon.ax.press(openBtn)
    }
    guard let window = await daemon.ax.pluginWindow(track: name) else {
        throw ToolFailure(error: "could not open plugin '\(groups[slot].name)' on '\(name)'", layer: "ax",
                          expected: "an open plugin window titled '\(name)'", observed: "no plugin window")
    }
    let params = await daemon.ax.paramControls(in: window)
    guard !params.isEmpty else {
        throw ToolFailure(error: "plugin parameters not accessible via AX", layer: "ax",
                          expected: "addressable parameter sliders", observed: "opaque plugin view")
    }
    return (name, window, params)
}
```

`GetPluginParamsTool.invoke`:
```swift
        let (name, _, params) = try await axEnterPlugin(daemon, trackName: trackName, slot: slot)
        var out: [Value] = []
        for (i, param) in params.enumerated() {
            let display = await daemon.ax.stringValue(.title, of: param.handle)
                ?? await daemon.ax.value(of: param.handle).map { String($0) } ?? ""
            out.append(.object(["index": .int(i), "name": .string(param.name), "display": .string(display)]))
        }
        return .object(["track": .string(name), "slot": .int(slot), "params": .array(out)])
```

`SetPluginParamTool.invoke` (keep the arg parsing for `slot`/`param`/`value` 0…1):
```swift
        let (name, _, params) = try await axEnterPlugin(daemon, trackName: trackName, slot: slot)
        let wanted = paramKey.lowercased()
        let target = params.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in i < params.count ? params[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "ax",
                              expected: params.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard await daemon.ax.isSettable(target.handle) else {
            throw ToolFailure(error: "parameter '\(target.name)' not settable via AX", layer: "ax",
                              expected: "a settable control", observed: "read-only")
        }
        // Param values are raw engineering units in [min,max]; the contract's `value` is 0…1.
        // Map, then converge by nudging (AXSetValue moves ±1 per call — ax-findings.md).
        let (loOpt, hiOpt) = await daemon.ax.minMax(of: target.handle)
        guard let lo = loOpt, let hi = hiOpt, hi > lo else {
            throw ToolFailure(error: "parameter '\(target.name)' has no readable range", layer: "ax",
                              expected: "AXMinValue/AXMaxValue on the slider", observed: "missing range")
        }
        let rawTarget = lo + value * (hi - lo)
        let steps = Int((hi - lo).rounded(.up)) + 2
        _ = try await daemon.ax.nudgeToRaw(target.handle, target: rawTarget, maxSteps: steps)
        let display = await daemon.ax.stringValue(.title, of: target.handle)
            ?? await daemon.ax.value(of: target.handle).map { String($0) } ?? ""
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_param", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(display)"))
        return .object(["param": .string(target.name), "display": .string(display)])
```

**Confirm the normalized-value assumption** against the fixture: if Logic's plugin `AXSlider`
uses a 0…1 value, `setValue(value…)` is direct; if it uses engineering units, map `value`
(0…1) across the control's `AXMinValue`/`AXMaxValue` (add `minMax(of:)` to the provider). The
fixture tells you which. If the fixture shows the plugin view opaque, keep BOTH tools returning
the structured "not accessible" error and mark them so in the smoke log — do not reactivate MCU.

- [ ] **Step 5: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: PASS.

- [ ] **Step 6: Full suite + commit**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`
Expected: all green.

```bash
git add Sources/LogicMCPCore/Tools/PluginTools.swift Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "feat(ax): plugin params via AX per-strip; disable wrong-track MCU plugin path"
```

---

## Task 11: Integration verification against real Logic + smoke-log update

**Files:**
- Modify: `docs/integration-smoke.md` (add AX-specific rows + a new run log)
- Modify: `CLAUDE.md` status block + `.superpowers/sdd/HANDOFF.md` (reflect the AX pivot)

No unit code; this task drives the real app and records ground truth (the project's core value).

- [ ] **Step 1: Rebuild and reconnect** — `perl -e 'alarm 600; exec @ARGV' swift build`; in Logic keep the Mixer window open; reconnect the MCP `serve` (`/mcp` → reconnect) so it holds the ports and the fresh binary is live.

- [ ] **Step 2: Run the mixer checklist via MCP tools**, Logic in the BACKGROUND (another app frontmost), recording each result:
  - `refresh_state` → names/pan/mute/solo/output match the project, full untruncated names.
  - `set_volume {track, db:-6}` → Logic shows −6.0; tool `source:"ax"`.
  - `set_volume {track, delta:+2}` → lands ≈ −4.0.
  - `set_pan {track, position:-30}` → strip shows ≈ L30; tool returns −30.
  - `set_mute` on/off, including idempotent re-call; **and** mute-by-hand-then-`set_mute(off)` (the Phase 1 stale-cache case — must now reflect truth because AX reads live).
  - `set_send {track, bus, level:90}` → knob moves; returned level matches (or structured "not accessible" if the fixture said opaque).
  - `get_plugin_params` on `vox` EQ → real names/displays; **run 5×** and confirm it is the SAME track every time (the wrong-track bug cannot recur).
  - `set_plugin_param` → control moves; display matches.

- [ ] **Step 3: Confirm no focus theft** — during all of Step 2, the frontmost app never changed to Logic. Note it explicitly (this is the whole thesis).

- [ ] **Step 4: Record** a new dated row in `docs/integration-smoke.md`'s log with the Logic version and pass/fail per item, plus a short "AX pivot" note. Update `CLAUDE.md`'s status section (Phase 2 done, AX primary for mixer) and trim `HANDOFF.md`'s "dangerous bug" section to "resolved by the AX pivot (Phase 2)."

- [ ] **Step 5: Commit**

```bash
git add docs/integration-smoke.md CLAUDE.md .superpowers/sdd/HANDOFF.md
git commit -m "docs: Phase 2 AX mixer core verified on real Logic; update status and smoke log"
```

---

## Self-review notes (author)

- **Spec coverage:** AXProvider/SystemAXProvider/FakeAXTree (T1–2), AXBridge (T3), AXMixer +
  refresh/query re-home (T4), set_volume/pan/mute/solo (T5–7), settle deadline (T8), set_send
  (T9), plugin get/set + MCU-path disable (T10), axdump diagnostic (T2), integration smoke
  (T11), `output` on TrackState (T4). Non-goals (structure, VisionVerifier, auto-fallback,
  signing) are not tasked — correct.
- **Probe-conditionality** is handled by capturing real fixtures in T2 and building fakes to
  match, with each probe-dependent tool (T9/T10) carrying an explicit "if the fixture shows it
  opaque/settable-false → structured error, never MCU" branch. No task is a placeholder waiting
  on the probe.
- **Type consistency:** `AXHandle`, `AXAttr`, `AXAction`, `AXProvider` methods, `AXStripControls`
  fields, `AXBridge` method names, and `ProjectModel.replaceTracks(_ controls:)`/`indexOf` are
  used identically across tasks.
- **Known soft spots the implementer must resolve from the T2 fixtures (flagged inline):** exact
  pan unit range (±64 vs 0…127), the silence glyph in the dB title, the send control's real
  description/settability, the plugin param value convention (0…1 vs engineering units), and
  whether the volume slider is directly settable (bisect) or must be stepped. Each has a
  concrete default and a fixture-confirmed correction path.
