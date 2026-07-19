# Arrange "Control Room" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent no-focus control of Logic's arrange-window "Control Room" — project tempo, time/key signature, playhead, cycle — plus the track-selection primitive that re-enables `delete_track` (and, if it commits, `rename_track`).

**Architecture:** A new **control-bar engine** added to `AXBridge` (the actor that owns the `AXProvider` seam) resolves the arrange window's `AXGroup "Control Bar"` and its named children, plus the per-track arrange-header `Has Focus` radios. New tools in `ArrangeTools.swift` drive these via the existing converge (`nudgeToRaw`), popup (`selectEnumChoice`), and menu (`pressMenuPath`) primitives, each self-verified against a fresh re-read. `delete_track`/`rename_track` in `StructureTools.swift` are re-enabled on top of a confirmed selection.

**Tech Stack:** Swift 6, Swift Package Manager, the MCP Swift SDK (`MCP` module), XCTest with an in-memory `FakeAXProvider` tree (AX needs real Logic → unit tests parse/drive fakes; a live `smoke --arrange` is the ship gate).

## Global Constraints

- **No-focus invariant:** never activate Logic or set it frontmost. Providers MUST NOT call activate; the smoke asserts Logic is not frontmost after the run.
- **Stale-handle discipline:** after ANY mutation, re-resolve elements BY NAME from a fresh walk and settle-poll; never trust a captured handle or an AX return code across a mutation.
- **Verified ground truth:** every write returns the value obtained from a fresh re-read; never fabricate `verified:true`. An unreachable/encoded target returns the achieved value with `verified:false`, and does not throw.
- **Structured errors:** failures throw `ToolFailure(error:layer:expected:observed:)` with `layer` one of `"ax" | "mcu" | "model" | "daemon"`.
- **Numeric args:** read integers via `args[k]?.coercedInt` and doubles via `args[k]?.coercedDouble` (JSON `-12` decodes to `.int`, `-12.5` to `.double`; the SDK accessors are case-strict).
- **No auto-commits of the repo by the harness** beyond the per-task `git commit` steps below; do not push. (Project rule: the user controls merges.)
- **Test runner:** `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test` (macOS has no `timeout`; kill orphaned xctest first — see the swift-test-gotchas memory).
- **Real-Logic ground truth** for this surface is `.superpowers/sdd/ax-findings.md` → "ARRANGE / GLOBAL-TRACK / MIDI feasibility probe (2026-07-18)". Read it before Task 0.

---

## Task 0: Live actuation probe (decision gate)

**Files:**
- Modify (findings only): `.superpowers/sdd/ax-findings.md` (append a dated "Plan A Task 0" finding)
- Capture: `Tests/LogicMCPCoreTests/Fixtures/ax/arrange_controlbar.txt`, `arrange_header.txt`

**Interfaces:**
- Produces: a one-paragraph finding fixing (a) the control-bar slider write primitive, (b) whether `AXPress` on `Has Focus` sets selection no-focus, (c) whether cycle markers are settable and share the playhead-thumb encoding, (d) whether the arrange track-name field commits no-focus, (e) the undo branch for tempo/signature edits. These gate Tasks 5–8's "ships or defers" decision, but every tool below is written regardless.

This task is a live investigation (no unit test); its deliverable is the recorded finding + fixtures. Logic must be running with `mcp_test.logicx` open. Uses the read-only/press `axdump` diagnostics already in `Sources/logic-mcp/AXDump.swift`.

- [ ] **Step 1: Build the CLI**

Run: `swift build --product logic-mcp`
Expected: `Build … complete!`

- [ ] **Step 2: Characterize the control-bar write primitive (absolute vs ±1-nudge)**

The `nudgeToRaw` converger works for BOTH families (it calls `setNumber(target)` in a loop and reads back — absolute reaches in one call, nudge in N), so the goal here is only to CONFIRM `AXSetValue` moves the Tempo slider at all and record the shape. Read the current tempo, then set it and observe:

Run: `.build/debug/logic-mcp axdump deep "tracks" 6 | grep -i "Tempo\|Playhead\|bar\|beat"`
Record: the `AXSlider description="Tempo"` value, and the `bar`/`beat` slider values, and their `settable` flags.

Manually (in Logic) note the tempo, then confirm the slider is `settable=true`. Record in the finding: "control-bar Tempo/playhead are `settable=true`; `nudgeToRaw` will be used (absolute reaches in 1 step)."

- [ ] **Step 3: Confirm `Has Focus` press-to-select works no-focus**

Run (selects Track 1 “vox” by pressing its Has Focus radio):
`.build/debug/logic-mcp axdump press "tracks" "Has Focus" 6 AXRadioButton | grep -i "Has Focus\|Track "`
Then re-dump and read every header's `Has Focus`:
`.build/debug/logic-mcp axdump deep "tracks" 8 | grep -A1 "Track [0-9].*“" | grep "Has Focus"`
Expected (the make-or-break): exactly ONE header now reads `Has Focus value="1"` and it is the pressed one; Logic did not come frontmost.
Record the result. **If press-to-select does NOT work, Tasks 5–7 SHIP THE TOOLS BUT return a structured "selection not available" error at runtime** (the tests still pass on the fake); note this in the finding.

- [ ] **Step 4: Cycle markers — settable + shared encoding with the playhead thumb**

Set the playhead to a known bar and read the `Playhead thumb` encoded value; then check whether `Start Marker`/`End Marker` accept a set to that raw:
`.build/debug/logic-mcp axdump deep "tracks" 8 | grep -i "Playhead thumb\|Start Marker\|End Marker"`
Record whether `Start`/`End Marker` are `settable=true` and whether their values are in the same units as `Playhead thumb`. **If not cleanly settable, Task 8 ships only the enable/disable toggle and defers range-by-bar to Plan B** (record this).

- [ ] **Step 5: Rename commit + undo registration**

Try setting a track-name field and re-reading; and after a tempo change, check `Edit ▸ Undo`'s title:
`.build/debug/logic-mcp axdump menu "Edit" | grep -i "Undo"`
Record: does the name field commit no-focus (gates Task 7)? Does a tempo edit create an `Undo …` entry (gates Task 2's undo branch: Logic-undo vs self-journal)?

- [ ] **Step 6: Capture fixtures + write the finding**

Save the control-bar and one header subtree:
`.build/debug/logic-mcp axdump deep "tracks" 8 > Tests/LogicMCPCoreTests/Fixtures/ax/arrange_controlbar.txt`
Append a dated "Plan A Task 0" paragraph to `.superpowers/sdd/ax-findings.md` recording (a)–(e) above.

- [ ] **Step 7: Commit**

```bash
git add Tests/LogicMCPCoreTests/Fixtures/ax/arrange_controlbar.txt .superpowers/sdd/ax-findings.md
git commit -m "chore(arrange): Task 0 live actuation probe — control-bar/selection/cycle/rename/undo findings + fixtures"
```

---

## Task 1: Control-bar engine on AXBridge

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (append the arrange engine — must live here to access the `private let p`, same as the mixer/plugin engines)
- Test: `Tests/LogicMCPCoreTests/ArrangeEngineTests.swift` (create)

**Interfaces:**
- Consumes: `AXBridge`'s `private let p: AXProvider`; the existing `public func descendant(of:role:description:) -> AXHandle?`.
- Produces:
  - `public func arrangeWindow() -> AXHandle?`
  - `public func controlBar() -> AXHandle?`
  - `public func controlBarControl(role: String, description: String) -> AXHandle?`
  - `public func arrangeHeaderItems() -> [(name: String, item: AXHandle)]`
  - `public func hasFocusRadio(in item: AXHandle) -> AXHandle?`
  - `nonisolated static func parseTrackHeaderName(_ desc: String) -> String?`

- [ ] **Step 1: Write the failing test**

Create `Tests/LogicMCPCoreTests/ArrangeEngineTests.swift`:

```swift
import XCTest
@testable import LogicMCPCore

final class ArrangeEngineTests: XCTestCase {
    /// Build a minimal fake tree: an arrange window ("… - Tracks") with a Control Bar (Tempo +
    /// bar/beat + Time/Key Sig popups) and a Tracks header with two track items each carrying a
    /// Has Focus radio — plus a DECOY mixer window ("… - Mixer: Tracks") that must NOT be matched.
    private func makeTree() -> FakeAXProvider {
        let tempo = FakeAXNode(role: "AXSlider", description: "Tempo", value: 120, settable: true,
                               minValue: 5, maxValue: 990)
        let bar = FakeAXNode(role: "AXSlider", description: "bar", value: 1, settable: true, minValue: 1, maxValue: 999)
        let beat = FakeAXNode(role: "AXSlider", description: "beat", value: 1, settable: true, minValue: 1, maxValue: 16)
        let timeSig = FakeAXNode(role: "AXPopUpButton", description: "Time Signature", stringValue: "4/4")
        let keySig = FakeAXNode(role: "AXPopUpButton", description: "Key Signature", stringValue: "C Major")
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar",
                                 children: [tempo, bar, beat, timeSig, keySig])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])

        func header(_ n: Int, _ name: String, focused: Bool) -> FakeAXNode {
            let radio = FakeAXNode(role: "AXRadioButton", description: "Has Focus",
                                   stringValue: focused ? "1" : "0")
            let nameField = FakeAXNode(role: "AXTextField", description: name, value: 0)
            return FakeAXNode(role: "AXLayoutItem", description: "Track \(n) “\(name)”",
                              children: [radio, nameField])
        }
        let hdr = FakeAXNode(role: "AXGroup", description: "Tracks header",
                             children: [header(1, "vox", focused: true), header(2, "Rugrats", focused: false)])
        let arrange = FakeAXNode(role: "AXWindow", title: "mcp_test.logicx - Tracks",
                                 children: [cbOuter, hdr])
        let mixer = FakeAXNode(role: "AXWindow", title: "mcp_test.logicx - Mixer: Tracks", children: [])
        let root = FakeAXNode(role: "AXApplication", children: [mixer, arrange])
        return FakeAXProvider(root: root)
    }

    func testArrangeWindowExcludesMixer() async {
        let bridge = AXBridge(provider: makeTree())
        let w = await bridge.arrangeWindow()
        XCTAssertNotNil(w)
        XCTAssertEqual(await bridge.stringValue(.title, of: w!), "mcp_test.logicx - Tracks")
    }

    func testControlBarGettersResolve() async {
        let bridge = AXBridge(provider: makeTree())
        let tempo = await bridge.controlBarControl(role: "AXSlider", description: "Tempo")
        XCTAssertEqual(await bridge.value(of: tempo!), 120)
        let key = await bridge.controlBarControl(role: "AXPopUpButton", description: "Key Signature")
        XCTAssertEqual(await bridge.stringValue(.value, of: key!), "C Major")
    }

    func testArrangeHeadersParseNamesAndFocus() async {
        let bridge = AXBridge(provider: makeTree())
        let items = await bridge.arrangeHeaderItems()
        XCTAssertEqual(items.map(\.name), ["vox", "Rugrats"])
        let voxFocus = await bridge.hasFocusRadio(in: items[0].item)
        XCTAssertEqual(await bridge.stringValue(.value, of: voxFocus!), "1")
    }

    func testParseTrackHeaderName() {
        XCTAssertEqual(AXBridge.parseTrackHeaderName("Track 2 “Rugrats”"), "Rugrats")
        XCTAssertNil(AXBridge.parseTrackHeaderName("Tracks header"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeEngineTests`
Expected: FAIL — `value of type 'AXBridge' has no member 'arrangeWindow'`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/LogicMCPCore/AX/AXBridge.swift` (inside the `AXBridge` actor body, before its closing brace):

```swift
    // MARK: - Arrange "Control Room" engine (Phase 5 Plan A)

    /// Logic's arrange window: the AXWindow whose title ends "- Tracks". The mixer window ends
    /// "Mixer: Tracks", so the suffix excludes it (and its Inspector mini-mixer). See ax-findings.md.
    public func arrangeWindow() -> AXHandle? {
        p.windows().first { (p.string(.title, of: $0) ?? "").hasSuffix("- Tracks") }
    }

    /// The inner `AXGroup description="Control Bar"` in the arrange window — its children include the
    /// Tempo slider, the Playhead bar/beat sliders, and the Time/Key Signature popups.
    public func controlBar() -> AXHandle? {
        guard let w = arrangeWindow() else { return nil }
        return descendant(of: w, role: "AXGroup", description: "Control Bar")
    }

    /// A named control-bar child by (role, description). nil if the arrange window or control is absent.
    public func controlBarControl(role: String, description: String) -> AXHandle? {
        guard let cb = controlBar() else { return nil }
        return descendant(of: cb, role: role, description: description)
    }

    /// Per-track arrange-header items under `AXGroup description="Tracks header"`, each described
    /// `Track N “name”`. Returns (parsed name, item handle) in tree order.
    public func arrangeHeaderItems() -> [(name: String, item: AXHandle)] {
        guard let w = arrangeWindow(),
              let header = descendant(of: w, role: "AXGroup", description: "Tracks header") else { return [] }
        return p.children(of: header).compactMap { item in
            guard p.string(.role, of: item) == "AXLayoutItem",
                  let desc = p.string(.description, of: item),
                  let name = Self.parseTrackHeaderName(desc) else { return nil }
            return (name, item)
        }
    }

    /// The `Has Focus` radio inside a header item (value "1" == focused track).
    public func hasFocusRadio(in item: AXHandle) -> AXHandle? {
        descendant(of: item, role: "AXRadioButton", description: "Has Focus")
    }

    /// `Track 2 “Rugrats”` → `Rugrats`; nil if `desc` is not a track-header wrapper.
    nonisolated static func parseTrackHeaderName(_ desc: String) -> String? {
        guard let open = desc.firstIndex(of: "“"), let close = desc.lastIndex(of: "”"), open < close
        else { return nil }
        return String(desc[desc.index(after: open)..<close])
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeEngineTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/ArrangeEngineTests.swift
git commit -m "feat(arrange): control-bar + track-header resolution engine on AXBridge"
```

---

## Task 2: `set_tempo` tool

**Files:**
- Create: `Sources/LogicMCPCore/Tools/ArrangeTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift:98` (register the tool, before `UndoStructuralTool`)
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift` (create)

**Interfaces:**
- Consumes: `AXBridge.controlBarControl(role:description:)`, `AXBridge.nudgeToRaw(_:target:maxSteps:)`, `AXBridge.minMax(of:)`, `AXBridge.value(of:)`.
- Produces: `public struct SetTempoTool: LogicTool` (name `"set_tempo"`); a shared `func arrangeControl(_ daemon:role:description:tool:) async throws -> AXHandle` helper in `ArrangeTools.swift`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogicMCPCoreTests/ArrangeToolTests.swift`:

```swift
import XCTest
import MCP
@testable import LogicMCPCore

final class ArrangeToolTests: XCTestCase {
    /// A daemon wired to a fake arrange tree. `nudge` models real-Logic ±1 sliders when true.
    func makeDaemon(_ provider: FakeAXProvider, nudge: Bool = false) async -> (Daemon, ToolRegistry) {
        provider.nudgeMode = nudge
        let (end, _) = InMemoryWire.pair()
        let daemon = await Daemon(wire: end, axProvider: provider)
        let reg = ToolRegistry()
        await daemon.registerAllTools(in: reg)
        return (daemon, reg)
    }

    func callJSON(_ reg: ToolRegistry, _ name: String, _ args: [String: Value]) async -> (String, Bool) {
        let r = await reg.call(name: name, arguments: args)
        let t = r.content.compactMap { if case .text(let s, _, _) = $0 { return s } else { return nil } }.joined()
        return (t, r.isError ?? false)
    }

    private func arrangeOnlyTree(tempo: Double = 120) -> FakeAXProvider {
        let t = FakeAXNode(role: "AXSlider", description: "Tempo", value: tempo, settable: true,
                           minValue: 5, maxValue: 990)
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [t])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetTempoAbsolute() async {
        let (_, reg) = await makeDaemon(arrangeOnlyTree(tempo: 120))
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .double(140)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"tempo\":140"), json)
        XCTAssertTrue(json.contains("\"verified\":true"), json)
    }

    func testSetTempoConvergesUnderNudge() async {
        let (_, reg) = await makeDaemon(arrangeOnlyTree(tempo: 120), nudge: true)
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .int(130)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"tempo\":130"), json)
    }

    func testSetTempoNoArrangeWindowErrors() async {
        let empty = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: []))
        let (_, reg) = await makeDaemon(empty)
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .int(120)])
        XCTAssertTrue(isErr)
        XCTAssertTrue(json.contains("arrange window"), json)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: FAIL — `unknown tool 'set_tempo'` (the registry returns an error string), so the `isErr` assertions about content fail.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LogicMCPCore/Tools/ArrangeTools.swift`:

```swift
import MCP

/// Resolve a named control-bar control or throw the standard "no arrange window / no control" error.
/// Shared by every arrange tool so the not-open-project path is identical everywhere.
func arrangeControl(_ daemon: Daemon, role: String, description: String, tool: String) async throws -> AXHandle {
    guard await daemon.ax.arrangeWindow() != nil else {
        throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                          expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
    }
    guard let control = await daemon.ax.controlBarControl(role: role, description: description) else {
        throw ToolFailure(error: "\(tool): control '\(description)' not found in the Control Bar", layer: "ax",
                          expected: "an \(role) description=\"\(description)\"", observed: "none")
    }
    return control
}

public struct SetTempoTool: LogicTool {
    public let name = "set_tempo"
    public let description = "Set the project tempo (BPM) via Logic's control bar, verified by re-reading the tempo. NOTE: this sets the tempo at the CURRENT playhead position — with the playhead at the start (or no tempo changes in the project) that is the project tempo. Editing a tempo map with multiple changes is a separate capability."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["bpm": .object(["type": .string("number"),
            "description": .string("Target tempo in beats per minute, e.g. 120 or 128.5")])]),
        "required": .array([.string("bpm")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard let bpm = args["bpm"]?.coercedDouble, bpm > 0 else {
            throw ToolFailure(error: "'bpm' must be a positive number", layer: "daemon")
        }
        let slider = try await arrangeControl(daemon, role: "AXSlider", description: "Tempo", tool: name)
        let (loO, hiO) = await daemon.ax.minMax(of: slider)
        // nudgeToRaw drives BOTH absolute and ±1-nudge sliders (Task 0): absolute reaches in one
        // AXSetValue, nudge in N. Cap steps to the slider's raw span so a nudge slider can still
        // traverse end-to-end; fall back to a generous cap if the range is unreadable.
        let steps = (loO != nil && hiO != nil && hiO! > loO!) ? Int((hiO! - loO!).rounded(.up)) + 2 : 2000
        let achieved = try await daemon.ax.nudgeToRaw(slider, target: bpm, maxSteps: steps)
        let verified = abs(achieved - bpm) <= 0.5
        return .object(["tempo": .double(achieved), "verified": .bool(verified)])
    }
}
```

Register it in `Sources/LogicMCPCore/Daemon.swift` immediately before `await registry.register(UndoStructuralTool(daemon: self))`:

```swift
        await registry.register(SetTempoTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): set_tempo via the control-bar Tempo slider (converge + verify)"
```

---

## Task 3: `set_time_signature` + `set_key_signature` tools

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/ArrangeTools.swift` (add both tools)
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register both, next to `SetTempoTool`)
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift` (add tests)

**Interfaces:**
- Consumes: `arrangeControl(...)`, `AXMenuDriver.selectEnumChoice(from:choice:)`, `AXBridge.stringValue(.value, of:)`.
- Produces: `public struct SetTimeSignatureTool` (`"set_time_signature"`), `public struct SetKeySignatureTool` (`"set_key_signature"`).

- [ ] **Step 1: Write the failing test**

Add to `ArrangeToolTests.swift`. This fake models a popup whose child AXMenu items become selectable; pressing the matching item sets the popup's value (via the item's `onPress`):

```swift
    private func popupTree(desc: String, initial: String, choices: [String]) -> (FakeAXProvider, FakeAXNode) {
        let popup = FakeAXNode(role: "AXPopUpButton", description: desc, stringValue: initial)
        let items = choices.map { c -> FakeAXNode in
            let item = FakeAXNode(role: "AXMenuItem", title: c)
            item.onPress = { [weak popup] in popup?.stringValue = c }   // Logic commits the popup value
            return item
        }
        popup.children = [FakeAXNode(role: "AXMenu", children: items)]
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [popup])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return (FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange])), popup)
    }

    func testSetTimeSignature() async {
        let (provider, _) = popupTree(desc: "Time Signature", initial: "4/4", choices: ["3/4", "4/4", "6/8"])
        let (_, reg) = await makeDaemon(provider)
        let (json, isErr) = await callJSON(reg, "set_time_signature", ["signature": .string("6/8")])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"display\":\"6/8\""), json)
        XCTAssertTrue(json.contains("\"verified\":true"), json)
    }

    func testSetKeySignatureUnknownChoiceErrorsWithList() async {
        let (provider, _) = popupTree(desc: "Key Signature", initial: "C Major", choices: ["C Major", "A Minor"])
        let (_, reg) = await makeDaemon(provider)
        let (json, isErr) = await callJSON(reg, "set_key_signature", ["key": .string("Z Lydian")])
        XCTAssertTrue(isErr)
        XCTAssertTrue(json.contains("A Minor"), json)   // error lists the live choices
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: FAIL — `unknown tool 'set_time_signature'`.

- [ ] **Step 3: Write minimal implementation**

Add to `ArrangeTools.swift`:

```swift
/// Shared: select a choice in a named control-bar popup, verified against the popup's re-read value.
private func selectControlBarPopup(_ daemon: Daemon, description: String, choice: String, tool: String) async throws -> Value {
    let popup = try await arrangeControl(daemon, role: "AXPopUpButton", description: description, tool: tool)
    try await daemon.menu.selectEnumChoice(from: popup, choice: choice)   // throws layer:"ax" listing choices on a miss
    let now = await daemon.ax.stringValue(.value, of: popup) ?? ""
    let verified = now.range(of: choice, options: .caseInsensitive) != nil
        || choice.range(of: now, options: .caseInsensitive) != nil
    return .object(["display": .string(now), "verified": .bool(verified)])
}

public struct SetTimeSignatureTool: LogicTool {
    public let name = "set_time_signature"
    public let description = "Set the project time signature via Logic's control-bar popup (e.g. '4/4', '6/8'), verified against the popup's displayed value."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["signature": .object(["type": .string("string"),
            "description": .string("e.g. '4/4', '3/4', '6/8'")])]),
        "required": .array([.string("signature")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let sig = try requireString(args, "signature", tool: name)
        return try await selectControlBarPopup(daemon, description: "Time Signature", choice: sig, tool: name)
    }
}

public struct SetKeySignatureTool: LogicTool {
    public let name = "set_key_signature"
    public let description = "Set the project key signature via Logic's control-bar popup (e.g. 'C Major', 'A Minor'), verified against the popup's displayed value."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["key": .object(["type": .string("string"),
            "description": .string("e.g. 'C Major', 'A Minor', 'G Major'")])]),
        "required": .array([.string("key")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let key = try requireString(args, "key", tool: name)
        return try await selectControlBarPopup(daemon, description: "Key Signature", choice: key, tool: name)
    }
}
```

Register both in `Daemon.swift` next to `SetTempoTool`:

```swift
        await registry.register(SetTimeSignatureTool(daemon: self))
        await registry.register(SetKeySignatureTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): set_time_signature + set_key_signature via control-bar popups"
```

---

## Task 4: `set_playhead` tool

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/ArrangeTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift`

**Interfaces:**
- Consumes: `arrangeControl(...)`, `AXBridge.nudgeToRaw`, `AXBridge.value(of:)`.
- Produces: `public struct SetPlayheadTool` (`"set_playhead"`).

- [ ] **Step 1: Write the failing test**

Add to `ArrangeToolTests.swift`:

```swift
    private func playheadTree(bar: Double = 1, beat: Double = 1) -> FakeAXProvider {
        let barS = FakeAXNode(role: "AXSlider", description: "bar", value: bar, settable: true, minValue: 1, maxValue: 999)
        let beatS = FakeAXNode(role: "AXSlider", description: "beat", value: beat, settable: true, minValue: 1, maxValue: 16)
        let pos = FakeAXNode(role: "AXGroup", description: "Playhead Position", children: [barS, beatS])
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [pos])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetPlayheadBarAndBeat() async {
        let (_, reg) = await makeDaemon(playheadTree())
        let (json, isErr) = await callJSON(reg, "set_playhead", ["bar": .int(9), "beat": .int(3)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"bar\":9"), json)
        XCTAssertTrue(json.contains("\"beat\":3"), json)
    }

    func testSetPlayheadBarOnlyDefaultsBeat() async {
        let (_, reg) = await makeDaemon(playheadTree(bar: 5, beat: 2))
        let (json, isErr) = await callJSON(reg, "set_playhead", ["bar": .int(12)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"bar\":12"), json)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests/testSetPlayheadBarAndBeat`
Expected: FAIL — `unknown tool 'set_playhead'`.

- [ ] **Step 3: Write minimal implementation**

Add to `ArrangeTools.swift`. The `bar`/`beat` sliders live under `AXGroup "Playhead Position"`, itself inside the Control Bar, so resolve via `controlBar()` → descendant:

```swift
public struct SetPlayheadTool: LogicTool {
    public let name = "set_playhead"
    public let description = "Move the playhead to a bar (and optional beat) via Logic's control bar, verified by re-reading the position. beat defaults to 1."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "bar": .object(["type": .string("integer"), "description": .string("Target bar (1-based)")]),
            "beat": .object(["type": .string("integer"), "description": .string("Target beat within the bar; defaults to 1")]),
        ]),
        "required": .array([.string("bar")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard let bar = args["bar"]?.coercedInt, bar >= 1 else {
            throw ToolFailure(error: "'bar' must be an integer ≥ 1", layer: "daemon")
        }
        let beat = args["beat"]?.coercedInt ?? 1
        guard beat >= 1 else { throw ToolFailure(error: "'beat' must be an integer ≥ 1", layer: "daemon") }

        guard await daemon.ax.arrangeWindow() != nil else {
            throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                              expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
        }
        guard let barS = await daemon.ax.controlBarControl(role: "AXSlider", description: "bar"),
              let beatS = await daemon.ax.controlBarControl(role: "AXSlider", description: "beat") else {
            throw ToolFailure(error: "playhead sliders not found in the Control Bar", layer: "ax",
                              expected: "AXSlider description=\"bar\" and \"beat\"", observed: "none")
        }
        let achievedBar = try await daemon.ax.nudgeToRaw(barS, target: Double(bar), maxSteps: 1200)
        let achievedBeat = try await daemon.ax.nudgeToRaw(beatS, target: Double(beat), maxSteps: 64)
        let verified = Int(achievedBar.rounded()) == bar && Int(achievedBeat.rounded()) == beat
        return .object(["bar": .int(Int(achievedBar.rounded())), "beat": .int(Int(achievedBeat.rounded())),
                        "verified": .bool(verified)])
    }
}
```

Register in `Daemon.swift`:

```swift
        await registry.register(SetPlayheadTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): set_playhead (bar/beat) via the control-bar position sliders"
```

---

## Task 5: `select_track` tool

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `arrangeHeader(named:)` convenience + `hasFocusValue`)
- Modify: `Sources/LogicMCPCore/Tools/ArrangeTools.swift` (add `SelectTrackTool` + a `confirmSelection` helper)
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift`

**Interfaces:**
- Consumes: `AXBridge.arrangeHeaderItems()`, `AXBridge.hasFocusRadio(in:)`, `AXBridge.press(_:)`, `AXBridge.stringValue(.value,of:)`.
- Produces:
  - `public func arrangeHeader(named: String) -> (item: AXHandle, focus: AXHandle?)?` on `AXBridge`
  - `public struct SelectTrackTool` (`"select_track"`)
  - `func selectTrackConfirmed(_ daemon:_ name:) async throws -> Bool` in `ArrangeTools.swift` (re-used by delete/rename): presses the target's Has Focus radio, then re-reads ALL headers and returns true iff exactly the named one is focused.

- [ ] **Step 1: Write the failing test**

The fake models a radio GROUP: pressing one Has-Focus radio sets it "1" and its siblings "0" (wire this with `onPress` closures that see all the radios). Add to `ArrangeToolTests.swift`:

```swift
    /// Arrange headers where pressing a Has-Focus radio behaves like a radio group.
    private func headersTree(_ names: [String], focusedIndex: Int) -> FakeAXProvider {
        var radios: [FakeAXNode] = []
        var items: [FakeAXNode] = []
        for (i, n) in names.enumerated() {
            let radio = FakeAXNode(role: "AXRadioButton", description: "Has Focus",
                                   stringValue: i == focusedIndex ? "1" : "0")
            radios.append(radio)
            let nameField = FakeAXNode(role: "AXTextField", description: n, value: 0)
            items.append(FakeAXNode(role: "AXLayoutItem", description: "Track \(i + 1) “\(n)”",
                                    children: [radio, nameField]))
        }
        for r in radios { r.onPress = { for x in radios { x.stringValue = (x === r) ? "1" : "0" } } }
        let hdr = FakeAXNode(role: "AXGroup", description: "Tracks header", children: items)
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [hdr])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSelectTrackFocusesExactlyOne() async {
        let (_, reg) = await makeDaemon(headersTree(["vox", "Rugrats", "bass"], focusedIndex: 0))
        let (json, isErr) = await callJSON(reg, "select_track", ["name": .string("Rugrats")])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"selected\":\"Rugrats\""), json)
        XCTAssertTrue(json.contains("\"confirmed\":true"), json)
    }

    func testSelectTrackUnknownNameErrors() async {
        let (_, reg) = await makeDaemon(headersTree(["vox", "bass"], focusedIndex: 0))
        let (json, isErr) = await callJSON(reg, "select_track", ["name": .string("nope")])
        XCTAssertTrue(isErr)
        XCTAssertTrue(json.contains("vox") && json.contains("bass"), json)   // lists available
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests/testSelectTrackFocusesExactlyOne`
Expected: FAIL — `unknown tool 'select_track'`.

- [ ] **Step 3: Write minimal implementation**

Add to `AXBridge.swift` (in the arrange engine section):

```swift
    /// The arrange header whose parsed name case-insensitively equals `named`, with its Has Focus radio.
    public func arrangeHeader(named: String) -> (item: AXHandle, focus: AXHandle?)? {
        guard let hit = arrangeHeaderItems().first(where: {
            $0.name.caseInsensitiveCompare(named) == .orderedSame
        }) else { return nil }
        return (hit.item, hasFocusRadio(in: hit.item))
    }

    /// The set of currently-focused header names (Has Focus == "1"). Read AFTER a select to confirm
    /// exactly one — the delete guard depends on this being unambiguous.
    public func focusedTrackNames() -> [String] {
        arrangeHeaderItems().compactMap { h in
            guard let r = hasFocusRadio(in: h.item), p.string(.value, of: r) == "1" else { return nil }
            return h.name
        }
    }
```

Add to `ArrangeTools.swift`:

```swift
/// Press the named track's Has Focus radio and confirm — via a fresh re-read — that EXACTLY that
/// track is now focused. Returns true iff confirmed. Throws layer:"ax" (listing names) if the track
/// name is unknown. The delete/rename guard depends on this: never mutate on an unconfirmed selection.
func selectTrackConfirmed(_ daemon: Daemon, _ name: String) async throws -> Bool {
    guard await daemon.ax.arrangeWindow() != nil else {
        throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                          expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
    }
    let names = await daemon.ax.arrangeHeaderItems().map(\.name)
    guard let header = await daemon.ax.arrangeHeader(named: name), let focus = header.focus else {
        throw ToolFailure(error: "no track '\(name)' in the arrange headers", layer: "ax",
                          expected: "one of: \(names.joined(separator: ", "))", observed: "no match")
    }
    try await daemon.ax.press(focus)
    // Selection re-renders headers; re-read from a fresh walk (never the captured handle).
    let focused = await daemon.ax.focusedTrackNames()
    return focused.count == 1 && focused[0].caseInsensitiveCompare(name) == .orderedSame
}

public struct SelectTrackTool: LogicTool {
    public let name = "select_track"
    public let description = "Select (focus) a track by name in Logic's arrange area, via the track header's Has Focus control, confirmed by re-reading that exactly that track is focused. This is what makes delete_track safe. Case-insensitive."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let confirmed = try await selectTrackConfirmed(daemon, name)
        return .object(["selected": .string(name), "confirmed": .bool(confirmed)])
    }
}
```

Register in `Daemon.swift`:

```swift
        await registry.register(SelectTrackTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): select_track via arrange-header Has Focus, confirmed by re-read"
```

---

## Task 6: Re-enable `delete_track` on a confirmed selection

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/StructureTools.swift:59-83` (rewrite `DeleteTrackTool`)
- Test: `Tests/LogicMCPCoreTests/StructureToolTests.swift` (add delete tests) — check the file for the existing test harness helpers and mirror them.

**Interfaces:**
- Consumes: `selectTrackConfirmed(_:_:)` (Task 5), `daemon.menu.pressMenuPath`, `currentTrackNames`, `settleTracks`.
- Produces: a working `DeleteTrackTool` that deletes the named track iff selection is confirmed, else refuses.

- [ ] **Step 1: Write the failing test**

Open `Tests/LogicMCPCoreTests/StructureToolTests.swift` and mirror its existing fake-tree + menu-bar helpers (it already tests create/undo). Add a fake whose arrange headers behave as a radio group AND whose `Track ▸ Delete Track` menu item removes the focused strip from the mixer. Add:

```swift
    func testDeleteTrackDeletesSelected() async {
        // Build: a mixer window with 3 strips (vox, Rugrats, bass), arrange headers as a radio group,
        // and a menu bar where "Track ▸ Delete Track" removes the currently-focused strip.
        // (Reuse this file's existing mixer/menu builders; wire Delete Track's onPress to remove the
        //  strip whose name == the focused header, mirroring real Logic's "delete the SELECTED track".)
        let fixture = ArrangeDeleteFixture(names: ["vox", "Rugrats", "bass"])
        let (_, reg) = await makeDaemonForDelete(fixture)
        let (json, isErr) = await callJSON(reg, "delete_track", ["name": .string("Rugrats")])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"deleted\":true"), json)
        XCTAssertFalse(fixture.currentMixerNames().contains("Rugrats"), "Rugrats should be gone")
        XCTAssertTrue(fixture.currentMixerNames().contains("vox"), "vox must remain")
    }

    func testDeleteTrackRefusesWhenSelectionUnconfirmed() async {
        // A fixture whose Has-Focus press does NOT change focus (models real Logic if press-to-select
        // failed) — delete must REFUSE and delete nothing.
        let fixture = ArrangeDeleteFixture(names: ["vox", "bass"], pressSelects: false)
        let (_, reg) = await makeDaemonForDelete(fixture)
        let (json, isErr) = await callJSON(reg, "delete_track", ["name": .string("bass")])
        XCTAssertTrue(isErr, json)
        XCTAssertTrue(json.contains("selection"), json)
        XCTAssertTrue(fixture.currentMixerNames().contains("bass"), "nothing deleted on unconfirmed selection")
    }
```

Implement `ArrangeDeleteFixture` and `makeDaemonForDelete` in the test file using the patterns already present (FakeAXNode mixer strips like `AXMixerTests`/`StructureToolTests` build, `makeMenuBar` for the Track menu, and the radio-group `onPress` wiring from Task 5). The fixture holds references so `currentMixerNames()` can assert post-state; `pressSelects:false` wires the radios' `onPress` to no-op.

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests/testDeleteTrackDeletesSelected`
Expected: FAIL — the current `DeleteTrackTool` always throws "not available", so `deleted:true` is absent and `isErr` is true.

- [ ] **Step 3: Write minimal implementation**

Replace `DeleteTrackTool` in `Sources/LogicMCPCore/Tools/StructureTools.swift` (lines 59–83) with:

```swift
public struct DeleteTrackTool: LogicTool {
    public let name = "delete_track"
    public let description = "Delete a track by name. Selects it first (via the arrange header's Has Focus) and CONFIRMS exactly that track is focused before invoking Track ▸ Delete Track — so it never deletes the wrong track. Refuses if selection can't be confirmed. Reversible via undo_structural."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        // Guard: SELECT the named track and confirm EXACTLY it is focused. Never proceed otherwise —
        // Track ▸ Delete Track acts on the SELECTED track, so an unconfirmed selection risks the
        // wrong-track destructive bug that disabled this tool (see ax-findings.md selection notes).
        let confirmed = try await selectTrackConfirmed(daemon, name)   // throws layer:"ax" if name unknown
        guard confirmed else {
            throw ToolFailure(error: "refusing to delete: could not confirm '\(name)' is the selected track", layer: "ax",
                              expected: "exactly '\(name)' focused after select", observed: "selection unconfirmed — nothing deleted")
        }
        let before = Set(try await currentTrackNames(daemon))
        try await daemon.menu.pressMenuPath(["Track", "Delete Track"])
        let after = try await settleTracks(daemon) { names in !names.contains(name) || names.count < before.count }
        guard !after.contains(name) else {
            throw ToolFailure(error: "delete not confirmed", layer: "ax",
                              expected: "'\(name)' gone from the mixer", observed: "still present")
        }
        return .object(["deleted": .bool(true), "track": .string(name)])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests`
Expected: PASS (existing create/undo tests + the two new delete tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/StructureTools.swift Tests/LogicMCPCoreTests/StructureToolTests.swift
git commit -m "feat(arrange): re-enable delete_track on a confirmed arrange selection (refuses if unconfirmed)"
```

---

## Task 7 (CONDITIONAL — only if Task 0 Step 5 showed the name field commits no-focus): Re-enable `rename_track`

If Task 0 showed the arrange track-name field does NOT commit no-focus, **skip this task** and leave `RenameTrackTool` as its structured error. Record the skip in `progress.md`.

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `arrangeNameField(in:)` + a `setStringValue` passthrough)
- Modify: `Sources/LogicMCPCore/Tools/StructureTools.swift:39-57` (rewrite `RenameTrackTool`)
- Test: `Tests/LogicMCPCoreTests/StructureToolTests.swift`

**Interfaces:**
- Consumes: `selectTrackConfirmed`, a new `AXBridge.setStringValue(_:of:)` (wraps `p.setString`), `AXBridge.arrangeHeader(named:)`.
- Produces: a working `RenameTrackTool`.

- [ ] **Step 1: Write the failing test**

```swift
    func testRenameTrackCommits() async {
        let fixture = ArrangeDeleteFixture(names: ["vox", "bass"])   // reuse; add a rename helper below
        let (_, reg) = await makeDaemonForDelete(fixture)
        let (json, isErr) = await callJSON(reg, "rename_track", ["track": .string("vox"), "to": .string("lead vox")])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"renamed\":\"lead vox\""), json)
    }
```

Extend `ArrangeDeleteFixture` so each header's name `AXTextField`'s `setString` updates the strip name (models a committing field).

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests/testRenameTrackCommits`
Expected: FAIL — current `RenameTrackTool` throws "not available".

- [ ] **Step 3: Write minimal implementation**

Add to `AXBridge.swift`:

```swift
    /// The name AXTextField in an arrange header item (its description is the current track name).
    public func arrangeNameField(in item: AXHandle) -> AXHandle? {
        p.children(of: item).first { p.string(.role, of: $0) == "AXTextField" }
    }
    public func setStringValue(_ s: String, of h: AXHandle) throws { try p.setString(s, of: h) }
```

Replace `RenameTrackTool` in `StructureTools.swift` with:

```swift
public struct RenameTrackTool: LogicTool {
    public let name = "rename_track"
    public let description = "Rename a track. Selects it, then sets the arrange header's name field, verified by re-reading the header name."
    public let inputSchema = trackArgSchema(["to": .object(["type": .string("string")])], required: ["to"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        let to = try requireString(args, "to", tool: name)
        let confirmed = try await selectTrackConfirmed(daemon, trackName)
        guard confirmed else {
            throw ToolFailure(error: "refusing to rename: could not confirm '\(trackName)' is selected", layer: "ax",
                              expected: "'\(trackName)' focused", observed: "selection unconfirmed")
        }
        guard let header = await daemon.ax.arrangeHeader(named: trackName),
              let field = await daemon.ax.arrangeNameField(in: header.item) else {
            throw ToolFailure(error: "no name field for '\(trackName)'", layer: "ax",
                              expected: "an arrange header name field", observed: "none")
        }
        try await daemon.ax.setStringValue(to, of: field)
        // Re-resolve by the NEW name from a fresh walk (rename re-renders the header).
        let renamed = await daemon.ax.arrangeHeaderItems().map(\.name).contains {
            $0.caseInsensitiveCompare(to) == .orderedSame
        }
        guard renamed else {
            throw ToolFailure(error: "rename not confirmed", layer: "ax",
                              expected: "a header named '\(to)'", observed: "unchanged")
        }
        return .object(["renamed": .string(to)])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/Tools/StructureTools.swift Tests/LogicMCPCoreTests/StructureToolTests.swift
git commit -m "feat(arrange): re-enable rename_track via the arrange header name field (Task-0 gated)"
```

---

## Task 8 (Task-0 gated): `set_cycle` — enable toggle + range via the playhead-thumb Rosetta stone

Ships the **enable/disable toggle** unconditionally (high-confidence: the `Cycle` checkbox is a press-only toggle). Ships the **range-by-bar** part only if Task 0 Step 4 confirmed the `Start`/`End Marker` indicators are settable and share the `Playhead thumb` encoding; the tool sets the playhead to each bar, reads the resulting encoded `Playhead thumb` value, and writes that raw to the marker (encoding-free). If Task 0 showed markers aren't settable that way, implement only the toggle and return a structured "range-by-bar deferred to a later plan" when `startBar`/`endBar` are supplied.

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (add `playheadThumb()` + `cycleMarker(_:)` accessors)
- Modify: `Sources/LogicMCPCore/Tools/ArrangeTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift`

**Interfaces:**
- Consumes: `arrangeControl`, `AXBridge.press`, `AXBridge.nudgeToRaw`, `AXBridge.value(of:)`.
- Produces: `public struct SetCycleTool` (`"set_cycle"`).

- [ ] **Step 1: Write the failing test (toggle path — always applies)**

```swift
    private func cycleTree(enabled: Bool) -> FakeAXProvider {
        // Cycle is a press-only checkbox (settable=false); the fake flips "1"/"0" on press.
        let cycle = FakeAXNode(role: "AXCheckBox", description: "Cycle", stringValue: enabled ? "1" : "0")
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cycle])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetCycleEnable() async {
        let (_, reg) = await makeDaemon(cycleTree(enabled: false))
        let (json, isErr) = await callJSON(reg, "set_cycle", ["enabled": .bool(true)])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"enabled\":true"), json)
    }

    func testSetCycleAlreadyInStateIsNoOp() async {
        let (_, reg) = await makeDaemon(cycleTree(enabled: true))
        let (json, isErr) = await callJSON(reg, "set_cycle", ["enabled": .bool(true)])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"enabled\":true"), json)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests/testSetCycleEnable`
Expected: FAIL — `unknown tool 'set_cycle'`.

- [ ] **Step 3: Write minimal implementation**

Add to `AXBridge.swift`:

```swift
    /// The ruler's `Playhead thumb` timeline indicator (encoded value; used as a bar→raw oracle).
    public func playheadThumb() -> AXHandle? {
        guard let w = arrangeWindow() else { return nil }
        return descendant(of: w, role: "AXValueIndicator", description: "Playhead thumb")
    }
    /// A cycle locator indicator: `which` is "Start Marker" or "End Marker".
    public func cycleMarker(_ which: String) -> AXHandle? {
        guard let w = arrangeWindow() else { return nil }
        return descendant(of: w, role: "AXValueIndicator", description: which)
    }
```

Add to `ArrangeTools.swift`:

```swift
public struct SetCycleTool: LogicTool {
    public let name = "set_cycle"
    public let description = "Enable or disable Logic's cycle (loop) mode, and optionally set its range by bar. 'enabled': turn cycle on/off (verified). 'startBar'/'endBar' (optional, together): set the cycle range; the range is set by moving the playhead to each bar and copying its timeline position to the locator (encoding-free)."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "enabled": .object(["type": .string("boolean")]),
            "startBar": .object(["type": .string("integer")]),
            "endBar": .object(["type": .string("integer")]),
        ]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        var result: [String: Value] = [:]

        if let enabled = args["enabled"]?.boolValue {
            let cycle = try await arrangeControl(daemon, role: "AXCheckBox", description: "Cycle", tool: name)
            let now = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
            if now != enabled { try await daemon.ax.press(cycle) }
            let after = (await daemon.ax.stringValue(.value, of: cycle)) == "1"
            result["enabled"] = .bool(after)
        }

        if let s = args["startBar"]?.coercedInt, let e = args["endBar"]?.coercedInt {
            guard s >= 1, e > s else { throw ToolFailure(error: "'startBar' ≥ 1 and 'endBar' > 'startBar' required", layer: "daemon") }
            guard let thumb = await daemon.ax.playheadThumb(),
                  let startM = await daemon.ax.cycleMarker("Start Marker"),
                  let endM = await daemon.ax.cycleMarker("End Marker"),
                  await daemon.ax.isSettable(startM), await daemon.ax.isSettable(endM) else {
                throw ToolFailure(error: "cycle range-by-bar is not available on this Logic build", layer: "ax",
                                  expected: "settable Start/End Marker indicators sharing the playhead-thumb encoding",
                                  observed: "markers not settable — set the cycle range in Logic, or use 'enabled' only")
            }
            // Rosetta stone: move the playhead to a bar, read its encoded timeline position, and write
            // that raw to the marker — no need to decode Logic's internal tick unit.
            func rawForBar(_ bar: Int) async throws -> Double {
                guard let barS = await daemon.ax.controlBarControl(role: "AXSlider", description: "bar") else {
                    throw ToolFailure(error: "no bar slider", layer: "ax", expected: "playhead bar slider", observed: "none")
                }
                _ = try await daemon.ax.nudgeToRaw(barS, target: Double(bar), maxSteps: 1200)
                return await daemon.ax.value(of: thumb) ?? 0
            }
            let rawStart = try await rawForBar(s)
            let rawEnd = try await rawForBar(e)
            _ = try await daemon.ax.nudgeToRaw(startM, target: rawStart, maxSteps: 4)
            _ = try await daemon.ax.nudgeToRaw(endM, target: rawEnd, maxSteps: 4)
            let gotStart = await daemon.ax.value(of: startM) ?? 0
            let gotEnd = await daemon.ax.value(of: endM) ?? 0
            result["startBar"] = .int(s); result["endBar"] = .int(e)
            result["rangeVerified"] = .bool(abs(gotStart - rawStart) < 1 && abs(gotEnd - rawEnd) < 1)
        }

        if result.isEmpty {
            throw ToolFailure(error: "set_cycle needs 'enabled' and/or 'startBar'+'endBar'", layer: "daemon")
        }
        return .object(result)
    }
}
```

Register in `Daemon.swift`:

```swift
        await registry.register(SetCycleTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS (toggle tests). (The range path is exercised live in Task 10; add a fake range test only if Task 0 confirmed the encoding, since modeling the thumb→marker raw copy in the fake mirrors that finding.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): set_cycle enable toggle + range-by-bar via playhead-thumb Rosetta (Task-0 gated)"
```

---

## Task 9: `get_arrange_state` read tool

A dedicated LIVE read tool (tempo / time sig / key sig / playhead / cycling). Kept separate from `get_project_overview`, whose contract is "cheap; does not touch Logic" (it reads the shadow model) — folding a live arrange read into it would break that contract.

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/ArrangeTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Test: `Tests/LogicMCPCoreTests/ArrangeToolTests.swift`

**Interfaces:**
- Consumes: the arrange engine getters + `stringValue`/`value`.
- Produces: `public struct GetArrangeStateTool` (`"get_arrange_state"`).

- [ ] **Step 1: Write the failing test**

```swift
    func testGetArrangeState() async {
        // Reuse a full tree: tempo 120, time 4/4, key C Major, playhead bar 1 beat 1, cycle off.
        let tempo = FakeAXNode(role: "AXSlider", description: "Tempo", value: 128, settable: true, minValue: 5, maxValue: 990)
        let bar = FakeAXNode(role: "AXSlider", description: "bar", value: 3, settable: true, minValue: 1, maxValue: 999)
        let beat = FakeAXNode(role: "AXSlider", description: "beat", value: 2, settable: true, minValue: 1, maxValue: 16)
        let pos = FakeAXNode(role: "AXGroup", description: "Playhead Position", children: [bar, beat])
        let time = FakeAXNode(role: "AXPopUpButton", description: "Time Signature", stringValue: "6/8")
        let key = FakeAXNode(role: "AXPopUpButton", description: "Key Signature", stringValue: "A Minor")
        let cycle = FakeAXNode(role: "AXCheckBox", description: "Cycle", stringValue: "1")
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [tempo, pos, time, key, cycle])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        let (_, reg) = await makeDaemon(FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange])))
        let (json, isErr) = await callJSON(reg, "get_arrange_state", [:])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"tempo\":128"), json)
        XCTAssertTrue(json.contains("\"timeSignature\":\"6/8\""), json)
        XCTAssertTrue(json.contains("\"keySignature\":\"A Minor\""), json)
        XCTAssertTrue(json.contains("\"bar\":3"), json)
        XCTAssertTrue(json.contains("\"cycling\":true"), json)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests/testGetArrangeState`
Expected: FAIL — `unknown tool 'get_arrange_state'`.

- [ ] **Step 3: Write minimal implementation**

Add to `ArrangeTools.swift`:

```swift
public struct GetArrangeStateTool: LogicTool {
    public let name = "get_arrange_state"
    public let description = "Read the arrange control bar live via Accessibility: tempo, time signature, key signature, playhead (bar/beat), and whether cycle is on. Touches Logic (unlike get_project_overview)."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        guard await daemon.ax.arrangeWindow() != nil else {
            throw ToolFailure(error: "no arrange window — is a project open in Logic?", layer: "ax",
                              expected: "an AXWindow titled \"… - Tracks\"", observed: "none")
        }
        func num(_ desc: String) async -> Double? {
            guard let h = await daemon.ax.controlBarControl(role: "AXSlider", description: desc) else { return nil }
            return await daemon.ax.value(of: h)
        }
        func popup(_ desc: String) async -> String? {
            guard let h = await daemon.ax.controlBarControl(role: "AXPopUpButton", description: desc) else { return nil }
            return await daemon.ax.stringValue(.value, of: h)
        }
        let cycling = (await {
            guard let c = await daemon.ax.controlBarControl(role: "AXCheckBox", description: "Cycle") else { return nil as String? }
            return await daemon.ax.stringValue(.value, of: c)
        }()) == "1"
        var obj: [String: Value] = ["cycling": .bool(cycling)]
        if let t = await num("Tempo") { obj["tempo"] = .double(t) }
        if let ts = await popup("Time Signature") { obj["timeSignature"] = .string(ts) }
        if let ks = await popup("Key Signature") { obj["keySignature"] = .string(ks) }
        if let b = await num("bar"), let be = await num("beat") {
            obj["playhead"] = .object(["bar": .int(Int(b.rounded())), "beat": .int(Int(be.rounded()))])
        }
        return .object(obj)
    }
}
```

Register in `Daemon.swift`:

```swift
        await registry.register(GetArrangeStateTool(daemon: self))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter ArrangeToolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicMCPCore/Tools/ArrangeTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/ArrangeToolTests.swift
git commit -m "feat(arrange): get_arrange_state live control-bar read"
```

---

## Task 10: Live `smoke --arrange` (ship gate)

**Files:**
- Modify: `Sources/logic-mcp/Smoke.swift` (add `@Flag var arrange` + `runArrange()`)

**Interfaces:**
- Consumes: all Task 2–9 tools through the `ToolRegistry`, exactly as `runStructural()` does.
- Produces: `logic-mcp smoke --arrange` printing per-step results + a net-zero + focus check.

This is a live harness, not a unit test; its passing run on real Logic is the ship gate.

- [ ] **Step 1: Add the flag + method**

In `Sources/logic-mcp/Smoke.swift`, add after `var structure = false`:

```swift
    @Flag(name: .long, help: "Run the arrange 'Control Room' smoke (set_tempo/time/key/playhead, select_track → delete_track → undo_structural, get_arrange_state) — net-zero.")
    var arrange = false
```

Change `run()`:

```swift
    func run() async throws {
        if arrange { try await runArrange() }
        else if structure { try await runStructural() }
        else { try await runMixer() }
    }
```

- [ ] **Step 2: Implement `runArrange()`**

Add a `runArrange()` mirroring `runStructural()`'s scaffolding (SystemAXProvider, InMemoryWire pair, daemon, registry, the `call`/`header` closures, and the FOCUS CHECK block). Sequence, capturing originals from `get_arrange_state` first and restoring at the end:

```swift
    private func runArrange() async throws {
        let front0 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let provider = try SystemAXProvider()
        let (end, _) = InMemoryWire.pair()
        let daemon = await Daemon(wire: end, axProvider: provider)
        let reg = ToolRegistry()
        await daemon.registerAllTools(in: reg)
        @discardableResult func call(_ n: String, _ a: [String: Value] = [:]) async -> String {
            let r = await reg.call(name: n, arguments: a)
            let t = r.content.compactMap { if case .text(let s, _, _) = $0 { return s } else { return nil } }.joined()
            print("→ \(n) \(a)\n    \(t)\((r.isError ?? false) ? "   [isError]" : "")"); return t
        }
        func header(_ s: String) { print("\n=== \(s) ===") }

        header("0. get_arrange_state — capture originals")
        let before = await call("get_arrange_state")

        header("1. set_tempo 128 then restore")
        await call("set_tempo", ["bpm": .double(128)])
        header("2. set_time_signature 6/8 ; set_key_signature A Minor")
        await call("set_time_signature", ["signature": .string("6/8")])
        await call("set_key_signature", ["key": .string("A Minor")])
        header("3. set_playhead bar 5")
        await call("set_playhead", ["bar": .int(5)])
        header("4. set_cycle enabled true (+ range 5..9 if supported)")
        await call("set_cycle", ["enabled": .bool(true), "startBar": .int(5), "endBar": .int(9)])

        header("5. create a scratch track, select it, delete it, undo (net-zero)")
        let created = await call("create_track", ["kind": .string("audio")])
        // parse the created name out of the JSON ("track":"…") the same way runStructural does,
        // then: select_track → delete_track → confirm gone. (No undo needed for delete if we just
        // created it; but exercise undo_structural to unwind the create if delete refuses.)
        // On delete success the scratch track is gone (net-zero). On refuse, call undo_structural.

        header("6. RESTORE originals (tempo/time/key/playhead/cycle) parsed from step 0")
        // set_tempo/time/key/playhead/cycle back to the captured `before` values.

        let front1 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("\n=== FOCUS CHECK ===\n    before=\(front0) after=\(front1) (Logic must NOT appear)")
        print("\n=== ARRANGE SMOKE COMPLETE ===")
        _ = (before, created)
    }
```

Fill the step-5 and step-6 bodies using the same JSON-field parsing helper `runStructural`/`runMixer` already define (`field(_ json:_ key:)`), restoring each captured scalar. Keep it net-zero: the scratch track is deleted (or undone), and every project scalar is set back to its step-0 value.

- [ ] **Step 3: Build**

Run: `swift build --product logic-mcp`
Expected: `Build … complete!`

- [ ] **Step 4: Run the live smoke (real Logic, mcp_test.logicx open)**

Run: `.build/debug/logic-mcp smoke --arrange`
Expected: every step prints a non-error result; `set_tempo`/`time`/`key`/`playhead` show `verified:true`; `select_track` shows `confirmed:true`; `delete_track` shows `deleted:true`; the scratch track is gone; the FOCUS CHECK shows Logic is not frontmost; final scalars match the step-0 capture (net-zero).

- [ ] **Step 5: Commit**

```bash
git add Sources/logic-mcp/Smoke.swift
git commit -m "test(arrange): live smoke --arrange ship gate (scalars + select→delete→undo, net-zero, no-focus)"
```

---

## Task 11: Docs — record findings + refresh status

**Files:**
- Modify: `.superpowers/sdd/progress.md` (append a Plan A ledger entry), `.superpowers/sdd/ax-findings.md` (fold any smoke-only findings), `CLAUDE.md` (status/tool count/next-phase), `.superpowers/sdd/HANDOFF.md` (state).

- [ ] **Step 1: Update progress.md**

Append a dated Plan A entry: tasks done, the Task-0 outcomes (which of cycle-range / rename shipped), the live-smoke result, and the new tool count.

- [ ] **Step 2: Update CLAUDE.md + HANDOFF.md**

Move Phase 5 Plan A from "STARTING/in progress" to shipped once the smoke passes; update the tool list (add `set_tempo`, `set_time_signature`, `set_key_signature`, `set_playhead`, `set_cycle`, `select_track`, `get_arrange_state`; note `delete_track` re-enabled and whether `rename_track` shipped); record the total green test count; leave Plan B (List-Editor engine) as the next phase.

- [ ] **Step 3: Full test suite green + commit**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`
Expected: all tests pass (228 prior + the new arrange tests).

```bash
git add CLAUDE.md .superpowers/sdd/progress.md .superpowers/sdd/ax-findings.md .superpowers/sdd/HANDOFF.md
git commit -m "docs(arrange): record Plan A findings + refresh status"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-18-arrange-control-room-design.md`):
- `set_tempo` → Task 2 ✓; `set_time_signature`/`set_key_signature` → Task 3 ✓; `set_playhead` → Task 4 ✓; `set_cycle` → Task 8 ✓; `select_track` → Task 5 ✓; `delete_track` re-enable → Task 6 ✓; `rename_track` (Task-0 gated) → Task 7 ✓; reads → Task 9 (`get_arrange_state`, a documented refinement of "fold into get_project_overview" — kept separate to preserve that tool's no-touch contract) ✓; Task 0 live probe → Task 0 ✓; testing (fixture/converger/live smoke) → per-task tests + Task 10 ✓; undo/safety (delete guard, undo branch) → Task 6 + Task 0 Step 5 ✓.
- Control-bar engine (spec Layer 1) → Task 1 ✓.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Task 6/7's fixture helper (`ArrangeDeleteFixture`) is described with the exact behaviors to model and points at the existing builders to mirror; Task 10's step-5/6 bodies name the exact helper (`field(_:_:)`) and behavior (parse created name, restore captured scalars) rather than leaving them blank.

**Type consistency:** `selectTrackConfirmed(_:_:)` defined in Task 5 and consumed unchanged in Tasks 6/7; `arrangeControl(_:role:description:tool:)` defined in Task 2 and reused in Tasks 3/8; engine methods (`arrangeWindow`, `controlBar`, `controlBarControl`, `arrangeHeaderItems`, `hasFocusRadio`, `arrangeHeader`, `focusedTrackNames`, `playheadThumb`, `cycleMarker`, `arrangeNameField`, `setStringValue`) are each defined once (Tasks 1/5/7/8) before use. Tool return keys are consistent with each tool's tests.

**Note on `.boolValue`:** the plan uses `args["enabled"]?.boolValue` (Task 8) and `args["confirm"]?.boolValue` exists in the codebase (RecordTool), so the accessor is available; if a given SDK build lacks it, pattern-match `.bool` in `arrangeControl`'s file once, mirroring `requireString`.
