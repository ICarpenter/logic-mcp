# Plugin-Control Core (Controls-View Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read and write *any* inserted plugin's parameters — Apple and third-party — no-focus and verified, by driving Logic's generic **Controls view** instead of each plugin's opaque custom UI.

**Architecture:** After opening a plugin window, switch it to Logic's Controls view (a uniform `AXTable` of named, unit-valued, settable rows), walk that table into a typed `PluginControl` list, and drive/verify each control through the existing `AXBridge` actor. This is Plan 1 of the phase spec (`docs/superpowers/specs/2026-07-15-plugin-control-suite-design.md`); the profile store and the remaining tools (`set_plugin_option`, `press_plugin_control`, `load_instrument`, presets, `learn_plugin`) are Plan 2.

**Tech Stack:** Swift, Swift Package Manager, XCTest. AX access via the `AXProvider` protocol (`SystemAXProvider` real / `FakeAXProvider` test). MCP tools implement `LogicTool`.

## Global Constraints

- **Per-task commits on `feat/plugin-control-core` only** (user-authorized for this execution). Each task ends with a conventional commit (`feat(ax): …`) on the branch. **Never merge to `main`** — the user controls that. Each task's final "commit" step is a real `git commit` on this branch.
- **No-focus invariant.** Providers/tools MUST NOT activate Logic or set it frontmost. Drive everything through AX press/read.
- **Never trust a handle across a mutation.** After any press/insert/open, re-resolve by name via a fresh walk — the codebase's #1 bug class. Settle-poll; never reuse a pre-mutation handle.
- **`AXSetValue` is a ±1 nudge, not an absolute set** (ax-findings.md). Converge every value write in a loop, reading an oracle each step.
- **Verify against an independent oracle.** For a slider, the oracle is the row's display string; report `verified:false` rather than fabricate a value.
- **Test hygiene** (memory: swift-test-gotchas): run `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`. In tests that build a `FakeLogic`, retain it so `[weak self]` doesn't drop enumeration.
- **Reconnect `/mcp` after any rebuild** before live-driving Logic, or the `serve` process runs stale code (`ping` reports `stale`).

---

## File Structure

- **Create** `Sources/LogicMCPCore/AX/PluginDisplay.swift` — pure display-string parser (`"15 %"` → number + unit). No AX deps; unit-testable in isolation.
- **Create** `Sources/LogicMCPCore/AX/PluginControls.swift` — the `PluginControl` value type (one Controls-table row).
- **Modify** `Sources/LogicMCPCore/AX/AXBridge.swift` — add `controlTable(in:)`, `switchToControlsView(_:)`, `convergeToDisplay(...)`; fix `pluginWindow(track:)` to not require an `AXSlider`.
- **Modify** `Sources/LogicMCPCore/Tools/PluginTools.swift` — replace `axEnterPlugin` with `axEnterPluginControls`; rewrite `GetPluginParamsTool` and `SetPluginParamTool` onto the Controls table.
- **Modify** `Sources/LogicMCPCore/Tools/PluginInsertTool.swift` — truncation-tolerant confirm.
- **Create** `Tests/LogicMCPCoreTests/PluginDisplayTests.swift` — parser tests.
- **Modify** `Tests/LogicMCPCoreTests/AXPluginToolTests.swift` — rewrite fakes to Controls-view shape.
- **Modify** `Tests/LogicMCPCoreTests/PluginInsertToolTests.swift` — add the truncation regression.
- **Create** fixtures under `Tests/LogicMCPCoreTests/Fixtures/ax/`: `plugin_controls_channeleq.txt`, `plugin_controls_compressor.txt`, `plugin_controls_uad_bx20.txt`, `plugin_controls_sketchcassette.txt`, `plugin_view_menu.txt`.

---

## Task 0: Capture the Controls-view fixtures (live Logic)

No TDD — this produces committed ground-truth fixtures the later tasks' tests parse. Requires Logic open with `mcp_test.logicx`, the Mixer window open, and a rebuilt `.build/debug/logic-mcp` (`swift build`). The UAD + SketchCassette Controls dumps already exist in this session's scratchpad and can be reused; Channel EQ / Compressor must be captured.

**Files:**
- Create: the five fixture `.txt` files listed above.

- [ ] **Step 1: Build the CLI and confirm Logic/mixer are up**

```bash
swift build 2>&1 | tail -3
.build/debug/logic-mcp axdump tree 2>&1 | grep -E '^AXWindow' | head
# Expect a line: AXWindow subrole="AXStandardWindow" title="…- Mixer: Tracks"
```

- [ ] **Step 2: Insert the four probe plugins (one at a time — never in parallel)**

Use the exact catalog names (a partial name lists candidates in the error's `observed`). `vox` already has Channel EQ, so only Compressor + the two third-party need inserting; put each on a scratch strip.

```bash
# discover exact third-party names if unknown:
#   .build/debug/logic-mcp axdump  (no insert CLI) — instead use the MCP insert_plugin with a partial
# Insert (via the MCP tool, server reconnected/fresh):
#   insert_plugin(track:"bass",  name:"Compressor")
#   insert_plugin(track:"guitar",name:"UAD AKG BX 20")
#   insert_plugin(track:"piano", name:"SketchCassette II")
```

- [ ] **Step 3: Open each plugin window and switch it to Controls view**

For each track, open the slot's plugin window (double-click the slot in Logic, or `get_plugin_params` to open it) and set the header `View:` dropdown to **Controls**. Leave all open.

- [ ] **Step 4: Dump and extract each plugin window into a fixture**

`axdump tree` emits every window; extract just the `AXWindow subrole="AXDialog" title="<track>"` block, and prepend a `#` provenance comment. Repeat per plugin (Channel EQ on vox, Compressor on bass, UAD on guitar, SketchCassette on piano):

```bash
DIR=Tests/LogicMCPCoreTests/Fixtures/ax
TREE=$(.build/debug/logic-mcp axdump tree 2>&1)
extract() { # $1 = track title, $2 = out file
  { echo "# Captured $(date +%F), Logic 12.3, mcp_test — '$1' plugin in CONTROLS view."
    echo "# The header 'view' AXMenuButton reads title=\"Controls\"; params are AXTable rows."
    echo "$TREE" | awk -v t="$1" '$0 ~ "AXWindow subrole=\"AXDialog\" title=\""t"\""{f=1} f&&/^AXWindow/&&$0 !~ "title=\""t"\""{exit} f{print}'
  } > "$DIR/$2"
}
extract vox    plugin_controls_channeleq.txt
extract bass   plugin_controls_compressor.txt
extract guitar plugin_controls_uad_bx20.txt
extract piano  plugin_controls_sketchcassette.txt
wc -l "$DIR"/plugin_controls_*.txt
```

Verify each file starts with `AXWindow subrole="AXDialog"`, contains `AXMenuButton description="view" title="Controls"`, and has `AXRow`/`AXCell`/`AXStaticText`/`AXSlider` rows.

- [ ] **Step 5: Capture the `view` menu items (for the switch test)**

In Logic, click a plugin's `View:` dropdown so its menu is open, then:

```bash
.build/debug/logic-mcp axdump tree 2>&1 \
  | awk '/AXMenuButton description="view"/{f=1} f{print} f&&/AXMenu /{c++} c&&/^AX/&&!/AXMenu|AXMenuItem/{exit}' \
  > Tests/LogicMCPCoreTests/Fixtures/ax/plugin_view_menu.txt
# Should contain AXMenuItem title="Controls" and AXMenuItem title="Editor"
```

- [ ] **Step 6: Undo the probe inserts (net-zero) and stage the fixtures**

```bash
# undo_structural once per insert you added (3×), verify strips return to prior plugin sets:
#   undo_structural  → "Undo Insert Plug-in in Channel Strip"  (×3)
.build/debug/logic-mcp axdump tree 2>&1 | grep -iE 'UAD|Sketch|Compressor on bass' || echo "clean"
git add Tests/LogicMCPCoreTests/Fixtures/ax/plugin_controls_*.txt Tests/LogicMCPCoreTests/Fixtures/ax/plugin_view_menu.txt
git commit -m "test(ax): capture Controls-view plugin fixtures (Task 0)"
```

Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 1: `PluginDisplay` — parse a display string into number + unit

**Files:**
- Create: `Sources/LogicMCPCore/AX/PluginDisplay.swift`
- Test: `Tests/LogicMCPCoreTests/PluginDisplayTests.swift`

**Interfaces:**
- Produces: `enum PluginDisplay { static func parse(_ s: String) -> Parsed }` and
  `struct PluginDisplay.Parsed: Equatable, Sendable { let number: Double?; let unit: String?; let raw: String }`.
  `number` is the leading signed decimal if present (else nil for enum text like `"Mono"`); `unit` is the trailing token (`"%"`, `"Hz"`, `"dB"`, `"ms"`, `"L"`, `"R"`, or `""` when a bare number, `nil` when no number).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LogicMCPCoreTests/PluginDisplayTests.swift
import XCTest
@testable import LogicMCPCore

final class PluginDisplayTests: XCTestCase {
    func testParsesNumberAndUnit() {
        XCTAssertEqual(PluginDisplay.parse("15 %"),   .init(number: 15,   unit: "%",  raw: "15 %"))
        XCTAssertEqual(PluginDisplay.parse("0.0 dB"), .init(number: 0,    unit: "dB", raw: "0.0 dB"))
        XCTAssertEqual(PluginDisplay.parse("0.18 Hz"),.init(number: 0.18, unit: "Hz", raw: "0.18 Hz"))
        XCTAssertEqual(PluginDisplay.parse("-6 dB"),  .init(number: -6,   unit: "dB", raw: "-6 dB"))
        XCTAssertEqual(PluginDisplay.parse("0 ms"),   .init(number: 0,    unit: "ms", raw: "0 ms"))
    }
    func testBareNumberHasEmptyUnit() {
        XCTAssertEqual(PluginDisplay.parse("1.00"), .init(number: 1.0, unit: "", raw: "1.00"))
        XCTAssertEqual(PluginDisplay.parse("100L"), .init(number: 100, unit: "L", raw: "100L"))
    }
    func testEnumTextHasNoNumber() {
        XCTAssertEqual(PluginDisplay.parse("Mono"), .init(number: nil, unit: nil, raw: "Mono"))
        XCTAssertEqual(PluginDisplay.parse("Off"),  .init(number: nil, unit: nil, raw: "Off"))
        XCTAssertEqual(PluginDisplay.parse("1/4"),  .init(number: nil, unit: nil, raw: "1/4"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter PluginDisplayTests`
Expected: FAIL — `cannot find 'PluginDisplay' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LogicMCPCore/AX/PluginDisplay.swift
import Foundation

/// Parses a Controls-view row's display string (Logic's human value, e.g. "15 %", "0.0 dB",
/// "Mono", "1/4") into a number + unit. The number is the verification oracle for a slider set;
/// enum-valued params (no leading number) parse to `number == nil`.
public enum PluginDisplay {
    public struct Parsed: Equatable, Sendable {
        public let number: Double?
        public let unit: String?
        public let raw: String
    }

    public static func parse(_ s: String) -> Parsed {
        let raw = s
        let str = s.trimmingCharacters(in: .whitespaces)
        // Leading signed decimal: optional '-', digits, optional '.digits'. A leading number that
        // is immediately followed by '/' (e.g. "1/4") is a fraction ENUM, not a scalar — reject.
        var idx = str.startIndex
        if idx < str.endIndex, str[idx] == "-" { idx = str.index(after: idx) }
        var sawDigit = false
        while idx < str.endIndex, str[idx].isNumber { idx = str.index(after: idx); sawDigit = true }
        if idx < str.endIndex, str[idx] == "." {
            idx = str.index(after: idx)
            while idx < str.endIndex, str[idx].isNumber { idx = str.index(after: idx); sawDigit = true }
        }
        guard sawDigit, !(idx < str.endIndex && str[idx] == "/") else {
            return Parsed(number: nil, unit: nil, raw: raw)
        }
        let numStr = String(str[str.startIndex..<idx])
        let unit = String(str[idx...]).trimmingCharacters(in: .whitespaces)
        return Parsed(number: Double(numStr), unit: unit, raw: raw)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter PluginDisplayTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Stage + request review**

```bash
git add Sources/LogicMCPCore/AX/PluginDisplay.swift Tests/LogicMCPCoreTests/PluginDisplayTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 2: `PluginControl` + `AXBridge.controlTable(in:)`

Walk a Controls-view window's `AXTable` into typed rows. Structure per the captured fixtures:
`AXTable → AXRow → AXCell → [AXStaticText label, AXGroup display, AXSlider|AXCheckBox|AXPopUpButton]`.

**Files:**
- Create: `Sources/LogicMCPCore/AX/PluginControls.swift`
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `controlTable(in:)` at end of the actor, before the closing brace)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift` (add a new test method)

**Interfaces:**
- Produces: `struct PluginControl: Sendable { enum Kind: String, Sendable { case slider, toggle, popup }; let index: Int; let name: String; let kind: Kind; let display: String?; let choices: [String]?; let settable: Bool; let handle: AXHandle; let displayHandle: AXHandle? }`
- Produces: `AXBridge.controlTable(in window: AXHandle) -> [PluginControl]` — empty array when there is no `AXTable` (opaque plugin).
- Consumes: existing `AXBridge.descendant(of:role:description:)`, `p.children(of:)`, `p.string(_:of:)`, `p.isSettable(_:)`.

- [ ] **Step 1: Write the failing test**

```swift
// add to AXPluginToolTests.swift
    /// A Controls-view window: one AXTable of rows, each a cell of [label, display group, control].
    /// Mirrors Fixtures/ax/plugin_controls_*.txt.
    private func controlsWindow(track: String) -> (window: FakeAXNode, rows: [FakeAXNode]) {
        func row(_ label: String, _ display: String, _ control: FakeAXNode) -> FakeAXNode {
            let cell = FakeAXNode(role: "AXCell", children: [
                FakeAXNode(role: "AXStaticText", stringValue: label),
                FakeAXNode(role: "AXGroup", stringValue: display),
                control,
            ])
            return FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])
        }
        let bass  = FakeAXNode(role: "AXSlider", value: 5000, settable: true, minValue: 0, maxValue: 10000)
        let type  = FakeAXNode(role: "AXPopUpButton", stringValue: "Standard")
        let direct = FakeAXNode(role: "AXCheckBox", stringValue: "0", settable: true)
        let rows = [row("Bass:", "0.00", bass), row("Tape Type:", "Standard", type),
                    row("Direct:", "", direct)]
        let table = FakeAXNode(role: "AXTable", children: rows)
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
        let window = FakeAXNode(role: "AXWindow", title: track, children: [
            FakeAXNode(role: "AXButton", description: "close"), viewBtn,
            FakeAXNode(role: "AXScrollArea", children: [table]),
        ])
        return (window, rows)
    }

    func testControlTableParsesRows() async throws {
        let (window, _) = controlsWindow(track: "vox")
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let handle = try await firstWindowHandle(bridge, title: "vox")
        let controls = await bridge.controlTable(in: handle)
        XCTAssertEqual(controls.map(\.name), ["Bass", "Tape Type", "Direct"])
        XCTAssertEqual(controls.map(\.kind), [.slider, .popup, .toggle])
        XCTAssertEqual(controls[0].display, "0.00")
        XCTAssertTrue(controls[0].settable)
    }

    /// Helper: resolve a window handle by title from a bare AXBridge.
    private func firstWindowHandle(_ bridge: AXBridge, title: String) async throws -> AXHandle {
        let ws = await bridge.windowsForTest()
        for w in ws where await bridge.titleForTest(w) == title { return w }
        throw XCTSkip("no window '\(title)'")
    }
```

Because `AXBridge` hides its provider, add two tiny test-only accessors to `AXBridge` in this step too (they read-only expose what tests need):

```swift
// AXBridge.swift — add near the other public reads
    /// Test-only: enumerate windows (mirrors the provider) so unit tests can grab a plugin window
    /// handle without a full Daemon. Safe: read-only.
    func windowsForTest() -> [AXHandle] { p.windows() }
    func titleForTest(_ h: AXHandle) -> String? { p.string(.title, of: h) }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests/testControlTableParsesRows`
Expected: FAIL — `value of type 'AXBridge' has no member 'controlTable'`.

- [ ] **Step 3: Write `PluginControl`**

```swift
// Sources/LogicMCPCore/AX/PluginControls.swift
/// One row of Logic's generic "Controls" view: a named parameter with its display value and
/// the settable AX control behind it. `handle` is re-resolved every call — never persisted.
public struct PluginControl: Sendable {
    public enum Kind: String, Sendable { case slider, toggle, popup }
    public let index: Int
    public let name: String
    public let kind: Kind
    public let display: String?         // the row's AXGroup value string ("15 %", "0.0 dB", "Off")
    public let choices: [String]?       // enum choices (nil in Plan 1 — populated by set_plugin_option)
    public let settable: Bool
    public let handle: AXHandle         // the AXSlider / AXCheckBox / AXPopUpButton
    public let displayHandle: AXHandle? // the sibling AXGroup carrying the live display (sliders)
}
```

- [ ] **Step 4: Write `controlTable(in:)`**

```swift
// AXBridge.swift — add inside the actor, after paramControls(in:)
    /// Walk a Controls-view plugin window's AXTable into typed rows. Returns [] if there is no
    /// table (an opaque plugin, or a window still in Editor view). Name comes from the cell's
    /// AXStaticText (trailing ':' trimmed); display from the sibling AXGroup (sliders) or the
    /// control's own value (toggle/popup).
    public func controlTable(in window: AXHandle) -> [PluginControl] {
        guard let table = descendant(of: window, role: "AXTable", description: nil) else { return [] }
        var out: [PluginControl] = []
        for row in p.children(of: table) where p.string(.role, of: row) == "AXRow" {
            guard let cell = p.children(of: row).first(where: { p.string(.role, of: $0) == "AXCell" })
            else { continue }
            let kids = p.children(of: cell)
            guard let label = kids.first(where: { p.string(.role, of: $0) == "AXStaticText" }),
                  var name = p.string(.value, of: label), !name.isEmpty else { continue }
            if name.hasSuffix(":") { name.removeLast() }
            guard let control = kids.first(where: {
                ["AXSlider", "AXCheckBox", "AXPopUpButton"].contains(p.string(.role, of: $0) ?? "")
            }) else { continue }
            let role = p.string(.role, of: control)
            let kind: PluginControl.Kind = role == "AXPopUpButton" ? .popup
                : (role == "AXCheckBox" ? .toggle : .slider)
            let group = kids.first(where: { p.string(.role, of: $0) == "AXGroup" })
            let display = kind == .slider ? group.flatMap { p.string(.value, of: $0) }
                                          : p.string(.value, of: control)
            out.append(PluginControl(index: out.count, name: name, kind: kind, display: display,
                                     choices: nil, settable: p.isSettable(control),
                                     handle: control, displayHandle: kind == .slider ? group : nil))
        }
        return out
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests/testControlTableParsesRows`
Expected: PASS.

- [ ] **Step 6: Add a fixture-parsing regression using the captured UAD dump**

```swift
// add to AXPluginToolTests.swift — proves the real UAD Controls dump parses (third-party coverage)
    func testControlTableParsesUADFixture() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("plugin_controls_uad_bx20"))
        let handle = try await firstWindowHandle(bridge, title: "guitar")
        let controls = await bridge.controlTable(in: handle)
        XCTAssertTrue(controls.contains { $0.name == "Dry/Wet" }, "UAD params must be named")
        XCTAssertTrue(controls.contains { $0.name == "Bass" && $0.kind == .slider })
    }
```

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests/testControlTableParsesUADFixture`
Expected: PASS. (Depends on Task 0's `plugin_controls_uad_bx20.txt`; the window title in the fixture is the track it was captured on — adjust the `firstWindowHandle` title to match.)

- [ ] **Step 7: Stage + request review**

```bash
git add Sources/LogicMCPCore/AX/PluginControls.swift Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 3: `switchToControlsView(_:)` + opaque-safe window detection

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift`
- Test: `Tests/LogicMCPCoreTests/AXBridgeTests.swift` (add methods)

**Interfaces:**
- Produces: `AXBridge.switchToControlsView(_ window: AXHandle) async throws` — no-op if the `view` menu already reads `Controls`; presses `view` then its `Controls` item otherwise; throws `ToolFailure(layer:"ax")` if there is no `view` menu or no `Controls` item.
- Modifies: `AXBridge.pluginWindow(track:)` — detect by title + a `close` button + a `view` menu button, **not** by requiring an `AXSlider` (opaque Editor views have none).

- [ ] **Step 1: Write the failing tests**

```swift
// add to AXBridgeTests.swift
    /// A plugin window that starts in Editor view; pressing view→Controls swaps title to "Controls".
    func testSwitchToControlsPressesMenuItem() async throws {
        let controlsItem = FakeAXNode(role: "AXMenuItem", title: "Controls")
        let editorItem   = FakeAXNode(role: "AXMenuItem", title: "Editor")
        let menu = FakeAXNode(role: "AXMenu", children: [controlsItem, editorItem])
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor",
                                 children: [menu])
        controlsItem.onPress = { viewBtn.title = "Controls" }   // Logic reflects the choice
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"), viewBtn,
        ])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let h = try XCTUnwrap(await bridge.windowsForTest().first)
        try await bridge.switchToControlsView(h)
        XCTAssertEqual(await bridge.titleForViewMenuTest(h), "Controls")
    }

    /// An opaque plugin (no AXSlider anywhere) must still be found as a plugin window.
    func testPluginWindowDetectsOpaqueWindow() async throws {
        let window = FakeAXNode(role: "AXWindow", title: "guitar", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
            FakeAXNode(role: "AXGroup", subrole: "AXUnknown", title: "SomeAU"),  // opaque, no slider
        ])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let found = await bridge.pluginWindow(track: "guitar")
        XCTAssertNotNil(found, "an opaque plugin window (no slider) must still be detected")
    }
```

Add a test-only accessor used above:

```swift
// AXBridge.swift — near windowsForTest()
    func titleForViewMenuTest(_ window: AXHandle) -> String? {
        descendant(of: window, role: "AXMenuButton", description: "view").flatMap { p.string(.title, of: $0) }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXBridgeTests/testSwitchToControlsPressesMenuItem`
Expected: FAIL — `no member 'switchToControlsView'`.

- [ ] **Step 3: Implement `switchToControlsView` and fix detection**

```swift
// AXBridge.swift — add inside the actor
    /// Switch a plugin window to Logic's generic "Controls" view. No-op if already there. The
    /// `view` control is an AXMenuButton (description="view"); its title reflects the current view.
    /// close-then-open reverts to Editor, so tools call this on every open before reading the table.
    public func switchToControlsView(_ window: AXHandle) async throws {
        guard let viewMenu = descendant(of: window, role: "AXMenuButton", description: "view") else {
            throw ToolFailure(error: "no view switcher on this plugin window", layer: "ax",
                              expected: "an AXMenuButton description=\"view\"", observed: "none")
        }
        if p.string(.title, of: viewMenu) == "Controls" { return }
        try? p.perform(.press, on: viewMenu)                 // open the menu
        try? await Task.sleep(for: .milliseconds(40))
        let items = p.children(of: viewMenu).flatMap { c -> [AXHandle] in
            p.string(.role, of: c) == "AXMenu" ? p.children(of: c) : []
        }
        guard let controls = items.first(where: { p.string(.title, of: $0) == "Controls" }) else {
            throw ToolFailure(error: "no 'Controls' view for this plugin", layer: "ax",
                              expected: "a 'Controls' menu item", observed:
                                "available: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
        }
        try p.perform(.press, on: controls)
        try? await Task.sleep(for: .milliseconds(40))
    }
```

Replace the body of `pluginWindow(track:)` (currently requires an `AXSlider`) with title + close + view detection:

```swift
    public func pluginWindow(track: String) -> AXHandle? {
        p.windows().first {
            (p.string(.title, of: $0) ?? "") == track
                && descendant(of: $0, role: nil, description: "close") != nil
                && descendant(of: $0, role: "AXMenuButton", description: "view") != nil
        }
    }
```

- [ ] **Step 4: Keep the still-Editor plugin-tool tests green (cross-task fix)**

The new `pluginWindow(track:)` now requires a `view` AXMenuButton. The existing Editor-shape plugin
windows in `Tests/LogicMCPCoreTests/AXPluginToolTests.swift` — the one built by `makeProvider()`, and
the per-slot windows in `testGetPluginParamsSlot1DoesNotReturnSlot0` and
`testGetPluginParamsOpaquePluginReturnsStructuredError` — have a `close` button and sliders but **no
`view` menu**, so `pluginWindow` (called via `axEnterPlugin`, which the get/set tools still use until
Task 4) will stop detecting them and those tests will fail. To each of those `AXWindow` fakes, add a
`view` menu child so detection still succeeds (they remain Editor-path tests until Task 4):

```swift
        FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
```

(The Task-2 windows that call `controlTable` directly — `controlsWindow`, the UAD fixture, the opaque
`testControlTableOpaquePluginReturnsEmpty` window — do NOT go through `pluginWindow`, so leave them.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXBridgeTests`
then the FULL suite: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`
Expected: both new AXBridge tests pass, and the full suite is green (no AXPluginToolTests regressions
from the `pluginWindow` change).

- [ ] **Step 6: Stage + request review**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/AXBridgeTests.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 4: `axEnterPluginControls` + upgrade `get_plugin_params`

Repoint the plugin tools onto the Controls table. Replaces `axEnterPlugin` (Editor-slider reader).

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift`
- Modify: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift` (rewrite fakes to Controls shape)

**Interfaces:**
- Produces: `func axEnterPluginControls(_ daemon: Daemon, trackName: String, slot: Int) async throws -> (name: String, window: AXHandle, controls: [PluginControl])` — resolves the strip, closes-then-opens the slot's window, switches to Controls, walks the table. Throws `ToolFailure(layer:"ax")` for a bad slot; returns an empty `controls` for an opaque plugin (caller decides).
- `GetPluginParamsTool` returns `{track, slot, opaque: Bool, params: [{index, name, kind, display, settable}]}`.
- Consumes: Task 2/3 (`controlTable`, `switchToControlsView`), existing `pluginGroups`, `closePluginWindows`, `descendant`.

- [ ] **Step 1: Rewrite the get_plugin_params tests to Controls shape**

Edit `AXPluginToolTests.swift`. **Keep** `makeProvider()` and the two set tests (`testSetPluginParamWritesAndVerifies`, `testSetPluginParamNegativeIndexDoesNotCrash`) — the *set* tool is still Editor-based until Task 5, so those must keep compiling and passing. **Delete** `testDuplicateParamNamesAreDeduped` (Editor-only concept — Controls has one row per param) and `testGetPluginParamsListsNames` (replaced). Add `makeControlsProvider()` and the new GET tests:

```swift
    /// A 'vox' strip whose Channel EQ slot, when opened, shows a Controls-view window.
    func makeControlsProvider() -> FakeAXProvider {
        let bass  = FakeAXNode(role: "AXSlider", value: 5000, settable: true, minValue: 0, maxValue: 10000)
        let group = FakeAXNode(role: "AXGroup", stringValue: "0.00")
        let cell  = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "Bass:"), group, bass])
        let table = FakeAXNode(role: "AXTable",
            children: [FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])])
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
        let close = FakeAXNode(role: "AXButton", description: "close")
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            close, viewBtn, FakeAXNode(role: "AXScrollArea", children: [table])])
        close.closesWindow = window
        let open = FakeAXNode(role: "AXButton", description: "open"); open.opensWindow = window
        let eqGroup = FakeAXNode(role: "AXGroup", description: "Channel EQ", children: [open])
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            eqGroup])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [
            FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area])]))
        p.nudgeMode = true
        return p
    }

    func testGetPluginParamsReturnsNamedControls() async throws {
        let d = await Daemon(wire: InMemoryWire(), axProvider: makeControlsProvider())
        _ = try await d.axMixer.syncTracks()
        let r = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
        guard case .object(let o) = r, case .array(let params)? = o["params"],
              case .object(let first)? = params.first else { return XCTFail() }
        XCTAssertEqual(first["name"], .string("Bass"))
        XCTAssertEqual(first["kind"], .string("slider"))
        XCTAssertEqual(o["opaque"], .bool(false))
    }
```

Update `testGetPluginParamsOpaquePluginReturnsStructuredError` to the Controls world: an opaque plugin window (view menu + close, but **no AXTable**) → `opaque:true`, empty params, no throw:

```swift
    func testGetPluginParamsOpaquePluginReportsOpaque() async throws {
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
        let close = FakeAXNode(role: "AXButton", description: "close")
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            close, viewBtn, FakeAXNode(role: "AXGroup", subrole: "AXUnknown", title: "OpaqueAU")])
        close.closesWindow = window
        let open = FakeAXNode(role: "AXButton", description: "open"); open.opensWindow = window
        let g = FakeAXNode(role: "AXGroup", description: "SomeThirdPartyAU", children: [open])
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"), g])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [
            FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area])]))
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        let r = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["opaque"], .bool(true))
        guard case .array(let params)? = o["params"] else { return XCTFail() }
        XCTAssertTrue(params.isEmpty)
    }
```

Keep `testGetPluginParamsSlot1DoesNotReturnSlot0` but give each slot a Controls-view window (view menu + close + a one-row table). Update its `eqWindow`/`compWindow` to include `FakeAXNode(role:"AXMenuButton", description:"view", title:"Controls")` and a table whose single row's label is `"Gain:"` / `"Threshold:"`, then assert the returned first param `name` is `"Gain"` / `"Threshold"`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: FAIL — the tool still returns the old Editor-shape output / uses `axEnterPlugin`.

- [ ] **Step 3: Add `axEnterPluginControls` and rewrite `GetPluginParamsTool`**

In `PluginTools.swift`, add the new entry function. **Do NOT delete `axEnterPlugin` yet** — `SetPluginParamTool` still calls it until Task 5, so removing it here would break compilation. (Leave the dead MCU `enterPluginEdit` block untouched — out of scope.)

```swift
/// Open the slot's plugin window via AX, switch it to Controls view, and return its parameter
/// rows. No MCU, no track selection, no wrong-track race. Empty `controls` == opaque plugin.
func axEnterPluginControls(_ daemon: Daemon, trackName: String, slot: Int) async throws
    -> (name: String, window: AXHandle, controls: [PluginControl]) {
    let strip = try await daemon.mixerStrip(named: trackName)
    let name = await daemon.ax.read(strip).name
    let groups = await daemon.ax.pluginGroups(strip)
    guard slot >= 0, slot < groups.count else {
        throw ToolFailure(error: "no plugin in slot \(slot) on '\(name)'", layer: "ax",
                          expected: "one of \(groups.count) plugin slots: \(groups.map(\.name).joined(separator: ", "))",
                          observed: "slot \(slot) out of range")
    }
    // Close every open window for this track first (windows key only on track title), then open
    // the REQUESTED slot deterministically — same discipline as before.
    await daemon.ax.closePluginWindows(track: name)
    if let openBtn = await daemon.ax.descendant(of: groups[slot].group, role: "AXButton", description: "open") {
        try? await daemon.ax.press(openBtn)
    }
    guard let window = await daemon.ax.pluginWindow(track: name) else {
        throw ToolFailure(error: "could not open plugin '\(groups[slot].name)' on '\(name)'", layer: "ax",
                          expected: "an open plugin window titled '\(name)'", observed: "no plugin window")
    }
    try await daemon.ax.switchToControlsView(window)
    let controls = await daemon.ax.controlTable(in: window)
    return (name, window, controls)
}

public struct GetPluginParamsTool: LogicTool {
    public let name = "get_plugin_params"
    public let description = "List a plugin's parameters (names, kinds, displayed values) from Logic's generic Controls view, read via Accessibility. Works for Apple and third-party plugins. slot is the 0-based index into the strip's plugin groups in tree order. 'opaque':true means the plugin exposes no addressable parameters."
    public let inputSchema = trackArgSchema(["slot": .object(["type": .string("integer")])], required: ["slot"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        let params: [Value] = controls.map { c in
            .object(["index": .int(c.index), "name": .string(c.name), "kind": .string(c.kind.rawValue),
                     "display": .string(c.display ?? ""), "settable": .bool(c.settable)])
        }
        return .object(["track": .string(name), "slot": .int(slot),
                        "opaque": .bool(controls.isEmpty), "params": .array(params)])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: PASS (rewritten get tests; slot1/negative-index still pass — negative-index moves to Task 5's set tool, keep its test compiling by leaving `SetPluginParamTool` intact until Task 5).

- [ ] **Step 5: Stage + request review**

```bash
git add Sources/LogicMCPCore/Tools/PluginTools.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 5: upgrade `set_plugin_param` (unit-or-normalized, display-oracle convergence)

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `convergeToDisplay`)
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift` (rewrite `SetPluginParamTool`)
- Modify: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`

**Interfaces:**
- Produces: `AXBridge.convergeToDisplay(slider: AXHandle, display: AXHandle, target: Double, tolerance: Double, maxSteps: Int) async throws -> Double?` — nudges the raw slider (assumes display increases with raw) until the parsed display number is within `tolerance` of `target` or it stalls; returns the achieved display number (nil if unreadable).
- `SetPluginParamTool` accepts `value` as a number in 0…1 (normalized) **or** a string with a unit (`"-6 dB"`, `"25 %"`). Returns `{param, display, verified}`.
- Consumes: `PluginDisplay.parse`, `controlTable`, `axEnterPluginControls`, `nudgeToRaw`, `minMax`, `setValue`.

- [ ] **Step 1: Write the failing test**

Model a slider whose display tracks its raw value (via `onSetNumber`), so convergence has a live oracle:

```swift
    /// A Controls window whose 'Bass' slider's display % follows its raw (raw/100), so a unit
    /// target converges against a live oracle — models Logic updating the display as you nudge.
    func makeConvergingProvider() -> (FakeAXProvider, FakeAXNode) {
        let group = FakeAXNode(role: "AXGroup", stringValue: "0 %")
        let bass  = FakeAXNode(role: "AXSlider", value: 0, settable: true, minValue: 0, maxValue: 10000)
        let cell  = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "Bass:"), group, bass])
        let table = FakeAXNode(role: "AXTable",
            children: [FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])])
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
        let close = FakeAXNode(role: "AXButton", description: "close")
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            close, viewBtn, FakeAXNode(role: "AXScrollArea", children: [table])])
        close.closesWindow = window
        let open = FakeAXNode(role: "AXButton", description: "open"); open.opensWindow = window
        let eqGroup = FakeAXNode(role: "AXGroup", description: "Channel EQ", children: [open])
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            eqGroup])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [
            FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area])]))
        p.nudgeMode = true
        p.onSetNumber = { node, raw in
            if node === bass { group.stringValue = "\(Int(raw / 100)) %" }   // display follows raw
        }
        return (p, bass)
    }

    func testSetPluginParamConvergesToUnitTarget() async throws {
        let (p, bass) = makeConvergingProvider()
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        let r = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Bass"), "value": .string("25 %")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["verified"], .bool(true))
        XCTAssertEqual(bass.numberValue, 2500, accuracy: 1)   // 25 % → raw 2500 (display = raw/100)
    }

    func testSetPluginParamNegativeIndexDoesNotCrash() async throws {  // keep — adapted to new provider
        let (p, _) = makeConvergingProvider()
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await SetPluginParamTool(daemon: d).invoke([
                "track": .string("vox"), "slot": .int(0), "param": .string("-1"), "value": .string("10 %")])
            XCTFail("expected a no-parameter ToolFailure")
        } catch let f as ToolFailure { XCTAssertTrue(f.error.contains("-1")) }
    }
```

Now that both tools are on the Controls path, **delete** the Editor-shape leftovers in this step: `makeProvider()`, the old `testSetPluginParamWritesAndVerifies`, and the old `testSetPluginParamNegativeIndexDoesNotCrash` (replaced by the two tests above). (`testDuplicateParamNamesAreDeduped` / `testGetPluginParamsListsNames` were removed in Task 4.)

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests/testSetPluginParamConvergesToUnitTarget`
Expected: FAIL — the tool doesn't accept a string `value` / doesn't return `verified`.

- [ ] **Step 3: Add `convergeToDisplay`**

```swift
// AXBridge.swift — inside the actor
    /// Nudge `slider` until the number parsed from `display`'s value string reaches `target`
    /// (±`tolerance`) or stalls. Assumes the display increases with the raw value (holds for the
    /// stock/third-party params probed 2026-07-15); breaks on a stuck read rather than looping.
    /// Returns the achieved display number, or nil if the display is unreadable.
    public func convergeToDisplay(slider: AXHandle, display: AXHandle, target: Double,
                                  tolerance: Double, maxSteps: Int) async throws -> Double? {
        let (loO, hiO) = minMax(of: slider)
        guard let lo = loO, let hi = hiO, hi > lo else { return nil }
        func liveNum() -> Double? { PluginDisplay.parse(p.string(.value, of: display) ?? "").number }
        var last: Double? = nil
        for _ in 0..<maxSteps {
            guard let cur = liveNum() else { return nil }
            if abs(cur - target) <= tolerance { return cur }
            try p.setNumber(cur < target ? hi : lo, of: slider)   // one nudge toward target
            let now = liveNum()
            if now == nil || now == cur || now == last { return now }   // stuck
            last = cur
        }
        return liveNum()
    }
```

- [ ] **Step 4: Rewrite `SetPluginParamTool`**

Also **delete `axEnterPlugin`** (the AX Editor-slider entry) now that neither tool uses it — `axEnterPluginControls` fully replaces it. Leave the dead MCU `enterPluginEdit`/`exitPluginEdit` block untouched.

```swift
// PluginTools.swift — replace SetPluginParamTool
public struct SetPluginParamTool: LogicTool {
    public let name = "set_plugin_param"
    public let description = "Set one plugin parameter via Logic's Controls view, verified against the parameter's displayed value. 'param': name (prefix ok) or integer index from get_plugin_params. 'value': a normalized number 0.0–1.0, OR a string with units matching the display (e.g. '-6 dB', '25 %'). Returns the display string Logic echoed and whether it verified."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("Parameter name (prefix ok) or integer index")]),
        "value": .object(["description": .string("Normalized 0–1 number, or a unit string like '-6 dB'")]),
    ], required: ["slot", "param", "value"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.coercedInt.map(String.init)
        guard let paramKey else { throw ToolFailure(error: "missing required argument 'param'", layer: "daemon") }

        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        let sliders = controls.filter { $0.kind == .slider }
        let wanted = paramKey.lowercased()
        let target = sliders.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in (0..<sliders.count).contains(i) ? sliders[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "ax",
                              expected: sliders.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard target.settable, let displayHandle = target.displayHandle else {
            throw ToolFailure(error: "parameter '\(target.name)' is not a settable slider", layer: "ax",
                              expected: "a settable slider with a display", observed: "not settable")
        }

        var verified = false
        if let unitStr = args["value"]?.stringValue, PluginDisplay.parse(unitStr).number != nil {
            // Unit target: converge against the display-string oracle.
            let goal = PluginDisplay.parse(unitStr).number!
            let achieved = try await daemon.ax.convergeToDisplay(
                slider: target.handle, display: displayHandle, target: goal, tolerance: 0.5, maxSteps: 600)
            verified = achieved.map { abs($0 - goal) <= 0.5 } ?? false
        } else if let norm = args["value"]?.coercedDouble, (0.0...1.0).contains(norm) {
            // Normalized target: map onto the slider's raw range and nudge there.
            let (loO, hiO) = await daemon.ax.minMax(of: target.handle)
            guard let lo = loO, let hi = hiO, hi > lo else {
                throw ToolFailure(error: "parameter '\(target.name)' has no readable range", layer: "ax",
                                  expected: "AXMinValue/AXMaxValue", observed: "missing range")
            }
            let rawTarget = lo + norm * (hi - lo)
            let achieved = try await daemon.ax.nudgeToRaw(target.handle, target: rawTarget,
                                                          maxSteps: Int((hi - lo).rounded(.up)) + 2)
            verified = abs(achieved - rawTarget) <= 1
        } else {
            throw ToolFailure(error: "'value' must be a 0.0–1.0 number or a unit string like '-6 dB'",
                              layer: "daemon")
        }

        let display = await daemon.ax.stringValue(.value, of: displayHandle) ?? ""
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_param", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(display)"))
        return .object(["param": .string(target.name), "display": .string(display), "verified": .bool(verified)])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: PASS (converge + negative-index; all prior plugin tests green).

- [ ] **Step 6: Stage + request review**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/Tools/PluginTools.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Task 6: truncation-tolerant `insert_plugin` confirm

Third-party names truncate in the strip's `AXGroup` description (`UAD AKG BX 20`→`UAD AKG BX`), so the current exact-match confirm false-negatives on a landed insert.

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginInsertTool.swift`
- Test: `Tests/LogicMCPCoreTests/PluginInsertToolTests.swift`

**Interfaces:**
- Produces: `func insertedNameMatches(group: String, requested: String) -> Bool` — case-insensitive, true if `group == requested` or `requested` starts with `group` (the strip truncates the tail). Used by the confirm predicate.

- [ ] **Step 1: Write the failing test**

```swift
// add to PluginInsertToolTests.swift
    func testConfirmMatchesTruncatedThirdPartyName() {
        XCTAssertTrue(insertedNameMatches(group: "UAD AKG BX", requested: "UAD AKG BX 20"))
        XCTAssertTrue(insertedNameMatches(group: "SketchCass", requested: "SketchCassette II"))
        XCTAssertTrue(insertedNameMatches(group: "Compressor", requested: "Compressor"))
        XCTAssertFalse(insertedNameMatches(group: "RetroSyn", requested: "UAD AKG BX 20"))
        XCTAssertFalse(insertedNameMatches(group: "", requested: "Compressor"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter PluginInsertToolTests/testConfirmMatchesTruncatedThirdPartyName`
Expected: FAIL — `cannot find 'insertedNameMatches' in scope`.

- [ ] **Step 3: Implement the helper and use it in the confirm**

```swift
// PluginInsertTool.swift — add above InsertPluginTool
/// Logic truncates a plugin's name in the strip's AXGroup description ("UAD AKG BX 20" → "UAD AKG
/// BX"), so the insert confirm must not require equality: a non-empty group name that is a
/// case-insensitive PREFIX of the requested name counts as a match.
func insertedNameMatches(group: String, requested: String) -> Bool {
    guard !group.isEmpty else { return false }
    let g = group.lowercased(), r = requested.lowercased()
    return g == r || r.hasPrefix(g)
}
```

Replace the two `caseInsensitiveCompare(plugin) == .orderedSame` checks in `InsertPluginTool.invoke`:

```swift
        let groups = await settlePluginsByName(daemon, track: track) { names in
            names.contains { insertedNameMatches(group: $0, requested: plugin) }
        }
        guard groups.contains(where: { insertedNameMatches(group: $0, requested: plugin) }) else {
            throw ToolFailure(error: "plugin insert not confirmed", layer: "ax",
                              expected: "'\(plugin)' in the strip's plugin slots",
                              observed: "slots: \(groups.joined(separator: ", "))")
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter PluginInsertToolTests`
Expected: PASS (helper test + existing insert tests).

- [ ] **Step 5: Full suite green**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 6: Stage + request review**

```bash
git add Sources/LogicMCPCore/Tools/PluginInsertTool.swift Tests/LogicMCPCoreTests/PluginInsertToolTests.swift
git commit -m "<conventional message for this task>"
```
Committed on `feat/plugin-control-core` (do not merge to main).

---

## Final: live smoke (manual gate)

After Task 6 and a `/mcp` reconnect, verify against real Logic on `mcp_test` (net-zero): insert Channel EQ / a third-party plugin → `get_plugin_params` returns named, unit-valued controls with `opaque:false` → `set_plugin_param(param:"Dry/Wet", value:"25 %")` returns `verified:true` and the display reads ~25 % → focus never stolen → undo the insert. Capture any surprises into `.superpowers/sdd/ax-findings.md`.
