# Plugin Write-Path Actuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the write half of Logic's Controls view work — set any inserted plugin's slider params by unit, select enum options, and press toggles/buttons — all no-focus and verified against the row's live display string.

**Architecture:** Plan 1 shipped the read path (`get_plugin_params` walks Logic's generic Controls-view `AXTable`). This plan reworks the broken slider write path (`convergeToDisplay` railed because it assumed the mixer's ±1-nudge model) into an **adaptive converger** whose actuation primitive is chosen by a live probe (Task 0), and adds two press-based tools (`set_plugin_option`, `press_plugin_control`). Every write verifies against the row's display-string oracle and is reversible via the existing `undo_last` journal.

**Tech Stack:** Swift, Swift Package Manager, XCTest. AX access via the `AXProvider` protocol (`SystemAXProvider` real / `FakeAXProvider` test). MCP tools implement `LogicTool`. Menus/popups via `AXMenuDriver`.

## Global Constraints

- **Per-task commits on `feat/plugin-actuation` only** (user-authorized for this execution). Each task ends with a conventional commit (`feat(ax): …`). **Never merge to `main`** — the user controls that. The design spec is already committed on this branch (`e954d53`).
- **No-focus invariant.** Providers/tools MUST NOT activate Logic or set it frontmost. Drive everything through AX press/read.
- **Never trust a handle across a mutation.** After any press/open, re-resolve by name via a fresh walk — the codebase's #1 bug class. Settle-poll; never reuse a pre-mutation handle.
- **Verify against an independent oracle.** For a slider, the oracle is the row's display string; report `verified:false` rather than fabricate a value. Never fabricate `verified:true`.
- **The actuation primitive is probe-gated.** `AXSetValue` on Controls-view Cocoa sliders does NOT behave like the mixer fader (2026-07-16 smoke: `setNumber(min)` drove the display to *max*). Task 0's live probe decides whether the converger defaults to `.absolute` (binary-search) or `.step` (increment/decrement). Both are implemented and tested; Task 0 only selects the default value of `defaultSliderActuation`.
- **Test hygiene** (memory: swift-test-gotchas): run `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test`. In tests that build a `FakeLogic`, retain it so `[weak self]` doesn't drop enumeration. macOS has no `timeout`; use the `perl -e 'alarm …'` wrapper.
- **Reconnect `/mcp` after any rebuild** before live-driving Logic, or the `serve` process runs stale code (`ping` reports `stale`). See memory: logic-mcp-dev-loop.
- **`mcp_test.logicx` is the disposable test project** — free to mutate; prefer net-zero. See memory: mcp-test-project-disposable.

---

## File Structure

- **Modify** `Sources/LogicMCPCore/AX/AXBridge.swift` — add `SliderActuation` enum + `defaultSliderActuation`; add `convergeAdaptive(...)` (both strategies + polarity probe + honest stall); in Task 2 delete the old `convergeToDisplay`.
- **Modify** `Sources/LogicMCPCore/AX/AXMenuDriver.swift` — add `selectEnumChoice(from:choice:)` (plain-menu enum select, distinct from the search-driven catalog popups).
- **Modify** `Sources/LogicMCPCore/AX/PluginControls.swift` — no shape change; `choices` is already a field (populated best-effort in Task 3).
- **Modify** `Sources/LogicMCPCore/Tools/PluginTools.swift` — rewire `SetPluginParamTool` onto `convergeAdaptive`; add `SetPluginOptionTool`, `PressPluginControlTool`; add undo `undoArguments` to all three setters.
- **Modify** `Sources/LogicMCPCore/AX/AXBridge.swift` (`controlTable`) — populate `choices` for `.popup` rows from a statically-present menu (best-effort).
- **Modify** `Sources/LogicMCPCore/Daemon.swift` — register the two new tools.
- **Modify** `Tests/LogicMCPCoreTests/FakeAXTree.swift` — `.increment`/`.decrement` fire `onSetNumber`; `.press` on an `AXCheckBox` flips `"0"`⇄`"1"`.
- **Create** `Tests/LogicMCPCoreTests/AXConvergerTests.swift` — direct converger tests (both strategies, polarity, honest stall).
- **Modify** `Tests/LogicMCPCoreTests/AXPluginToolTests.swift` — adapt the `set_plugin_param` tests to the new converger; add kind-mismatch, enum, press, and undo tests.
- **Create** fixtures under `Tests/LogicMCPCoreTests/Fixtures/ax/`: `plugin_controls_channeleq.txt`, `plugin_view_menu.txt`, `plugin_enum_popup.txt` (Task 0).
- **Modify** `docs/integration-smoke.md` — append the `--plugins` write-path checklist (Task 6).

---

## Task 0: Live actuation probe (decision gate, real Logic)

No TDD — this runs live and produces (a) captured fixtures the later tests parse and (b) a one-paragraph finding that selects the converger default, the undo branch, and the enum-select mechanism. Requires Logic open with `mcp_test.logicx`, the Mixer window open, and a rebuilt `.build/debug/logic-mcp` (`swift build`), `/mcp` reconnected.

**Files:**
- Create: `Tests/LogicMCPCoreTests/Fixtures/ax/plugin_controls_channeleq.txt`, `plugin_view_menu.txt`, `plugin_enum_popup.txt`
- Append the findings paragraph to `.superpowers/sdd/ax-findings.md` (gitignored — local record).

- [ ] **Step 1: Build the CLI and confirm Logic/mixer are up**

```bash
swift build 2>&1 | tail -3
.build/debug/logic-mcp axdump tree 2>&1 | grep -E '^AXWindow' | head
# Expect: AXWindow subrole="AXStandardWindow" title="… - Mixer: Tracks"
```

- [ ] **Step 2: Open a stock Channel EQ in Controls view and characterize the slider primitive**

Open `vox`'s Channel EQ (it already has one), switch it to Controls view. The Low Shelf Gain row is the known oracle: raw `0…480`, `dB=(raw−240)/10` (raw 240 = 0.0 dB, raw 480 = +24 dB). Using `axdump strip`/`tree`, record the RESULT of each primitive on that slider from a clean 0.0 dB start, restoring to 0.0 dB between trials:

1. `AXSetValue(v)` for `v ∈ {0, 120, 240, 360, 480}` and for `v ∈ {0.0, 0.5, 1.0}` — does the display land at the expected dB (absolute on raw), at a normalized position, or rail? Record raw→display for each.
2. `AXIncrement` ×N and `AXDecrement` ×N — does the raw move by a fixed amount each action? Record the per-action delta.
3. Undo probe: after a successful move, open Logic's Edit menu (`axdump menu Edit`) and record whether the top item reads "Undo <plugin-param-ish>" — i.e. did the move register a Logic undo entry?

**Decision recorded:** `defaultSliderActuation = .absolute` if `AXSetValue` lands at the requested raw (→ binary search); `.step` if only increment/decrement moves it predictably. And: undo registers / does not register.

- [ ] **Step 3: Capture the Channel EQ Controls-view fixture**

```bash
DIR=Tests/LogicMCPCoreTests/Fixtures/ax
TREE=$(.build/debug/logic-mcp axdump tree 2>&1)
{ echo "# Captured $(date +%F), Logic 12.3, mcp_test — 'vox' Channel EQ in CONTROLS view."
  echo "# Controls-view slider primitive per Task 0 probe: see ax-findings.md."
  echo "$TREE" | awk '/AXWindow subrole="AXDialog" title="vox"/{f=1} f&&/^AXWindow/&&!/title="vox"/{exit} f{print}'
} > "$DIR/plugin_controls_channeleq.txt"
grep -c 'AXRow' "$DIR/plugin_controls_channeleq.txt"   # expect several rows
```

Verify it starts with `AXWindow subrole="AXDialog"`, contains `AXMenuButton description="view" title="Controls"`, and has `AXRow`/`AXCell`/`AXStaticText`/`AXSlider`.

- [ ] **Step 4: Capture the `view` menu and an in-table enum popup**

Open a plugin whose Controls table has an enum param (e.g. a Compressor circuit-model or a Tape-Type-style popup). Press the in-table `AXPopUpButton` so its menu opens, then dump:

```bash
DIR=Tests/LogicMCPCoreTests/Fixtures/ax
.build/debug/logic-mcp axdump tree 2>&1 \
  | awk '/AXMenuButton description="view"/{f=1} f{print} f&&/AXMenu /{c++} c&&/^AX/&&!/AXMenu|AXMenuItem/{exit}' \
  > "$DIR/plugin_view_menu.txt"
# The enum popup: capture the AXPopUpButton and whether its open menu is a plain AXMenu of
# AXMenuItems (expected) or attaches an AXSearchField (large enum).
.build/debug/logic-mcp axdump tree 2>&1 \
  | awk '/AXPopUpButton/{f=1} f{print} f&&/AXMenuItem/{c++} c&&/^AXRow|^AXWindow/{exit}' \
  | head -40 > "$DIR/plugin_enum_popup.txt"
grep -E 'AXSearchField|AXMenuItem' "$DIR/plugin_enum_popup.txt" | head
```

**Decision recorded:** in-table enum → plain `AXMenu` (→ Task 3 `selectEnumChoice`) or `AXSearchField` (→ reuse `selectRoutingDestination`).

- [ ] **Step 5: Restore net-zero and commit the fixtures**

```bash
# Return the Low Shelf Gain to 0.0 dB; close the probe plugin windows. If any probe inserted a
# plugin, undo_structural once per insert. Confirm no stray plugins remain:
.build/debug/logic-mcp axdump tree 2>&1 | grep -iE 'AXWindow subrole="AXDialog"' || echo "no plugin windows open"
git add Tests/LogicMCPCoreTests/Fixtures/ax/plugin_controls_channeleq.txt \
        Tests/LogicMCPCoreTests/Fixtures/ax/plugin_view_menu.txt \
        Tests/LogicMCPCoreTests/Fixtures/ax/plugin_enum_popup.txt
git commit -m "test(ax): capture Controls-view write-path fixtures + record actuation probe (Task 0)"
```

Record the three decisions (slider primitive, undo registration, enum popup shape) in `.superpowers/sdd/ax-findings.md`. **These decisions drive Tasks 1–3.**

---

## Task 1: The adaptive converger (`convergeAdaptive`)

Add a new converger that reaches a display target using the probe-selected primitive, verified against the display-string oracle. Added as a NEW method so the existing `convergeToDisplay` + its tool call stay green until Task 2 rewires them.

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift`
- Modify: `Tests/LogicMCPCoreTests/FakeAXTree.swift` (increment/decrement fire `onSetNumber`)
- Test: `Tests/LogicMCPCoreTests/AXConvergerTests.swift` (create)

**Interfaces:**
- Consumes: `AXProvider` (`setNumber`, `perform(.increment/.decrement)`, `string(.value)`, `minMax`, `number`), `settledValue(of:unlessChangedFrom:)`, `PluginDisplay.parse`.
- Produces: `public enum SliderActuation { case absolute, step }`; `public static let defaultSliderActuation: SliderActuation`; `public func convergeAdaptive(slider:display:target:tolerance:actuation:maxSteps:) async throws -> Double?`.

- [ ] **Step 1: Extend the fake so a step also updates the display hook**

In `Tests/LogicMCPCoreTests/FakeAXTree.swift`, in `perform(_:on:)`, make the increment/decrement cases fire `onSetNumber` with the resulting value (so a test's display-follows-raw hook tracks steps, exactly as it does for `setNumber`):

```swift
case .increment: n.numberValue = (n.numberValue ?? 0) + 10; onSetNumber?(n, n.numberValue ?? 0)
case .decrement: n.numberValue = (n.numberValue ?? 0) - 10; onSetNumber?(n, n.numberValue ?? 0)
```

- [ ] **Step 2: Write the failing converger tests**

Create `Tests/LogicMCPCoreTests/AXConvergerTests.swift`. A tiny helper builds a bare slider+display pair inside an `AXBridge`; two providers — one absolute (`nudgeMode=false`), one where steps drive the display — exercise both strategies, plus an inverse-display case and an unreachable target.

```swift
import XCTest
@testable import LogicMCPCore

final class AXConvergerTests: XCTestCase {
    /// A bare AXBridge over one settable slider whose sibling AXGroup display follows the raw via
    /// `map`. `stepMode==false` → absolute setNumber (binary-search path); `true` → increment/
    /// decrement steps (step path). Returns the bridge, the slider handle, and the display handle.
    private func makeSliderBridge(min: Double, max: Double, start: Double,
                                  stepMode: Bool, map: @escaping (Double) -> String)
        async throws -> (AXBridge, AXHandle, AXHandle) {
        let slider = FakeAXNode(role: "AXSlider", value: start, settable: true, minValue: min, maxValue: max)
        let group = FakeAXNode(role: "AXGroup", stringValue: map(start))
        let root = FakeAXNode(role: "AXApplication", children: [group, slider])
        let p = FakeAXProvider(root: root)
        p.nudgeMode = false                       // absolute sets; step path uses inc/dec, unaffected
        p.onSetNumber = { n, raw in if n === slider { group.stringValue = map(raw) } }
        let bridge = AXBridge(provider: p)
        // Resolve handles by walking the bridge's provider view.
        let handles = try await bridge.childHandlesForTest(of: bridge.rootForTest())
        return (bridge, handles.slider, handles.display)
    }

    func testBinarySearchConvergesUp() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\(($0 - 240) / 10) dB"                // dB = (raw-240)/10  → raw 210 = -3 dB
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: -3,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), -3, accuracy: 0.5)
    }

    func testStepConvergesUp() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: true) {
            "\($0 / 10) %"                         // display = raw/10; step is ±10 raw → ±1 %
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 12,
                                                    tolerance: 0.5, actuation: .step, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 12, accuracy: 0.5)
    }

    func testBinarySearchHandlesInverseDisplay() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\((480 - $0) / 10) %"                 // display DECREASES as raw rises
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 12,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 12, accuracy: 0.5)
    }

    func testUnreachableTargetReturnsNearestNotFabricated() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\(($0 - 240) / 10) dB"                // reachable dB span is -24…+24
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 99,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 24, accuracy: 0.5)   // clamps at the +24 dB rail, honestly
    }
}
```

Add the two tiny test-only accessors to `AXBridge` (read-only, mirrors `windowsForTest`):

```swift
func rootForTest() -> AXHandle { (try? p.root()) ?? p.windows()[0] }
func childHandlesForTest(of h: AXHandle) -> (slider: AXHandle, display: AXHandle) {
    let kids = p.children(of: h)
    let slider = kids.first { p.string(.role, of: $0) == "AXSlider" }!
    let display = kids.first { p.string(.role, of: $0) == "AXGroup" }!
    return (slider, display)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXConvergerTests`
Expected: FAIL — `convergeAdaptive` / `SliderActuation` not defined.

- [ ] **Step 4: Implement `SliderActuation` + `convergeAdaptive` in `AXBridge.swift`**

Add near `convergeToDisplay` (leave the old method in place for now):

```swift
/// How a Controls-view slider actually moves under AX — SELECTED BY THE TASK 0 LIVE PROBE.
/// `.absolute`: AXSetValue lands the raw at the requested value → converge by binary search.
/// `.step`: only AXIncrement/AXDecrement move it, by a fixed amount → converge by linear stepping.
public enum SliderActuation: Sendable { case absolute, step }

/// The default the tools pass. SET THIS TO TASK 0's PROVEN PRIMITIVE at execution time. Both
/// branches below are implemented and unit-tested, so this is a one-line change either way.
public static let defaultSliderActuation: SliderActuation = .absolute

/// Converge `slider` until the number parsed from `display` reaches `target` (±`tolerance`), using
/// the probe-proven `actuation`. The DISPLAY STRING is the sole oracle; the raw value is only a
/// search coordinate (never assume a raw↔unit curve — the display may be nonlinear or inverse).
/// Returns the achieved display number, or nil if the display is unreadable. Never fabricates: an
/// unreachable target returns the nearest achieved value (the caller reports verified:false).
public func convergeAdaptive(slider: AXHandle, display: AXHandle, target: Double,
                             tolerance: Double, actuation: SliderActuation,
                             maxSteps: Int) async throws -> Double? {
    func disp() -> Double? { PluginDisplay.parse(p.string(.value, of: display) ?? "").number }
    switch actuation {
    case .absolute:
        let (loO, hiO) = p.minMax(of: slider)
        guard let lo = loO, let hi = hiO, hi > lo else { return nil }
        return try await convergeByBisection(slider: slider, disp: disp, lo: lo, hi: hi,
                                             target: target, tolerance: tolerance)
    case .step:
        return try await convergeByStepping(slider: slider, disp: disp,
                                            target: target, tolerance: tolerance, maxSteps: maxSteps)
    }
}

/// Binary-search the raw against the display oracle. Establishes polarity by sampling the display
/// at the two rails (the display may rise OR fall with raw), then bisects toward `target`. ~40
/// bisections cover any practical raw range. Reads the display only after the raw SETTLES
/// (`settledValue`) — an immediate post-write read can be stale (ax-findings.md).
private func convergeByBisection(slider: AXHandle, disp: () -> Double?, lo: Double, hi: Double,
                                 target: Double, tolerance: Double) async throws -> Double? {
    try p.setNumber(lo, of: slider); _ = await settledValue(of: slider, unlessChangedFrom: nil)
    guard let dLo = disp() else { return nil }
    try p.setNumber(hi, of: slider); _ = await settledValue(of: slider, unlessChangedFrom: lo)
    guard let dHi = disp() else { return nil }
    let ascending = dHi >= dLo                       // does a higher raw yield a higher display?
    var loR = lo, hiR = hi
    var best = disp()
    for _ in 0..<40 {
        let mid = (loR + hiR) / 2
        let before = p.number(of: slider)
        try p.setNumber(mid, of: slider)
        _ = await settledValue(of: slider, unlessChangedFrom: before)
        guard let d = disp() else { return best }
        best = d
        if abs(d - target) <= tolerance { return d }
        // Move toward the rail that pushes the display toward target, honoring polarity.
        if (target > d) == ascending { loR = mid } else { hiR = mid }
        if hiR - loR < 1 { break }                   // raw resolution exhausted → nearest is best
    }
    return best
}

/// Step-converge via AXIncrement/AXDecrement. One probe increment establishes the display polarity,
/// then steps toward `target`, re-reading the display each step. Bails honestly when the raw stops
/// moving (a genuine boundary) — settle-confirmed so an async-stale read isn't mistaken for stuck.
private func convergeByStepping(slider: AXHandle, disp: () -> Double?, target: Double,
                                tolerance: Double, maxSteps: Int) async throws -> Double? {
    guard let start = disp() else { return nil }
    let before = p.number(of: slider)
    try p.perform(.increment, on: slider)
    _ = await settledValue(of: slider, unlessChangedFrom: before)
    guard var cur = disp() else { return nil }
    let ascending = cur >= start                     // did the display rise on one increment?
    for _ in 0..<maxSteps {
        if abs(cur - target) <= tolerance { return cur }
        let up = (target > cur) == ascending
        let rawBefore = p.number(of: slider)
        try p.perform(up ? .increment : .decrement, on: slider)
        let settled = await settledValue(of: slider, unlessChangedFrom: rawBefore)
        if settled == nil || settled == rawBefore { return disp() }   // settle-confirmed stuck
        guard let now = disp() else { return cur }
        cur = now
    }
    return disp()
}
```

Add the two test-only accessors from Step 2 to `AXBridge`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXConvergerTests`
Expected: PASS (4/4).

- [ ] **Step 6: Run the full suite (nothing regressed — old converger untouched)**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all green (210 + 4 new).

- [ ] **Step 7: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/AXConvergerTests.swift Tests/LogicMCPCoreTests/FakeAXTree.swift
git commit -m "feat(ax): adaptive plugin-slider converger (binary-search + step, display oracle)"
```

---

## Task 2: Rewire `set_plugin_param` onto the adaptive converger

Switch `SetPluginParamTool` to `convergeAdaptive` with the Task-0 default, delete the old `convergeToDisplay`, and add the slider kind-mismatch guard. Update the tool's existing tests (they must now use `nudgeMode=false` for the `.absolute` default path).

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift`
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (delete old `convergeToDisplay`)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`

**Interfaces:**
- Consumes: `AXBridge.convergeAdaptive`, `AXBridge.defaultSliderActuation`, `AXBridge.nudgeToRaw` (normalized path, unchanged), `PluginControl`.
- Produces: `set_plugin_param` returning `{param, display, verified}`; rejects a `param` that resolves to a `.toggle`/`.popup` with a "wrong control kind" error.

- [ ] **Step 1: Update the converging tool tests to the new converger + add the kind-mismatch test**

These tool tests exercise whatever `AXBridge.defaultSliderActuation` Task 0 selected. **If Task 0 selected `.absolute`** (binary search on absolute sets): flip `p.nudgeMode = true` → `false` in ALL FOUR converge fakes — `makeConvergingProvider`, `makeMixedKindProvider`, the inline provider in `testSetPluginParamUnitTargetSettlesAsyncSliderReadback`, and any other converge test that sets `nudgeMode = true`. Their assertions still hold under absolute sets: 25 % → raw 2500 (bisect on 0…10000, display=raw/100), 0.5 → raw 5000 (normalized path, unchanged), index "2" → slider C, and the async-settle test converges 0→3 on 0…6 with `setValueLatency=1` still exercising `settledValue`. **If Task 0 selected `.step`** (increment/decrement, ±step per action): keep those fakes but retarget them to values reachable in whole steps of the fake's `.increment` delta (10) — e.g. the async-settle fake becomes range 0…60, target `"30 %"`, display=raw/10 — so a finite number of ±10 steps lands exactly. Then add the kind-mismatch test:

```swift
/// set_plugin_param must REFUSE a param that resolves to a non-slider (a toggle/popup), pointing
/// the caller at the right tool — never silently mis-actuate.
func testSetPluginParamRejectsToggleKind() async throws {
    let (p, _, _) = makeMixedKindProvider()          // rows: slider A, toggle B, slider C
    p.nudgeMode = false
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    _ = try await d.axMixer.syncTracks()
    do {
        _ = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("1"), "value": .double(0.5)])
        XCTFail("expected a wrong-kind ToolFailure for the toggle at index 1")
    } catch let f as ToolFailure {
        XCTAssertTrue(f.error.contains("not a settable slider") || f.error.contains("wrong control kind"))
    }
}
```

- [ ] **Step 2: Run to verify the kind test fails and see which converge tests break**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: the new kind test passes already (index 1 is a toggle → existing "not a settable slider" guard fires) OR fails only if the guard doesn't cover integer-index-to-toggle; the converge tests still pass because they call through the old `convergeToDisplay`. (This step confirms the starting state before the rewire.)

- [ ] **Step 3: Rewire `SetPluginParamTool` to `convergeAdaptive`**

In `PluginTools.swift`, in the unit-string branch, replace the `convergeToDisplay` call:

```swift
let achieved = try await daemon.ax.convergeAdaptive(
    slider: target.handle, display: displayHandle, target: goal, tolerance: 0.5,
    actuation: AXBridge.defaultSliderActuation, maxSteps: steps)
verified = achieved.map { abs($0 - goal) <= 0.5 } ?? false
```

The normalized-0–1 branch (`nudgeToRaw`) is unchanged. The existing guard `guard target.settable, let displayHandle = target.displayHandle` already rejects toggles/popups (they have `displayHandle == nil` or `settable == false`) with "not a settable slider" — that IS the kind-mismatch guard; keep it.

- [ ] **Step 4: Delete the now-unused old `convergeToDisplay`**

In `AXBridge.swift`, delete the entire old `convergeToDisplay(slider:display:target:tolerance:maxSteps:)` method (Task 1 replaced its role). Confirm no other caller:

```bash
grep -rn "convergeToDisplay" Sources Tests
# Expect: no matches (only convergeAdaptive remains).
```

- [ ] **Step 5: Run the tool tests to verify they pass**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXPluginToolTests`
Expected: PASS (all, including the converge tests now going through `convergeAdaptive`).

- [ ] **Step 6: Run the full suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/LogicMCPCore/Tools/PluginTools.swift Sources/LogicMCPCore/AX/AXBridge.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "feat(ax): set_plugin_param drives the adaptive converger (fixes railing write path)"
```

---

## Task 3: `set_plugin_option` — select an in-table enum choice

Add `selectEnumChoice` to `AXMenuDriver` (plain-menu select, per Task 0's finding), the `SetPluginOptionTool`, and best-effort `choices` population in `controlTable`. Register the tool.

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXMenuDriver.swift`
- Modify: `Sources/LogicMCPCore/AX/AXBridge.swift` (`controlTable` choices)
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift` (new tool)
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`

**Interfaces:**
- Consumes: `axEnterPluginControls` (returns `controls: [PluginControl]`), `PluginControl.handle` (the `AXPopUpButton`), `AXMenuDriver`.
- Produces: `public func selectEnumChoice(from popup: AXHandle, choice: String) async throws`; `SetPluginOptionTool` (`set_plugin_option`) returning `{param, display, verified}`.

> If Task 0's Step 4 finding is that in-table enums attach an `AXSearchField` (not a plain `AXMenu`), implement `selectEnumChoice` by delegating to the existing `selectRoutingDestination(from:dest:)` instead of the plain-menu walk below, and note it in the commit. The tool surface and tests are identical either way.

- [ ] **Step 1: Extend the fake so a popup press selects a choice; write the failing enum test**

The `controlsWindow` helper's `type` popup (`AXPopUpButton stringValue "Standard"`) needs an openable menu. Add a variant with menu children whose press sets the popup value, then the test:

```swift
/// A Controls window with an enum popup 'Tape Type' whose menu offers Standard/Vintage/Old; picking
/// a menu item sets the popup's displayed value (models Logic). Returns provider + the popup node.
private func makeEnumProvider() -> (FakeAXProvider, popup: FakeAXNode) {
    let popup = FakeAXNode(role: "AXPopUpButton", stringValue: "Standard")
    let items = ["Standard", "Vintage", "Old"].map { title -> FakeAXNode in
        let item = FakeAXNode(role: "AXMenuItem", title: title)
        item.onPress = { popup.stringValue = title }
        return item
    }
    popup.children = [FakeAXNode(role: "AXMenu", children: items)]
    let cell = FakeAXNode(role: "AXCell", children: [
        FakeAXNode(role: "AXStaticText", stringValue: "Tape Type:"),
        FakeAXNode(role: "AXGroup", stringValue: "Standard"), popup])
    let table = FakeAXNode(role: "AXTable",
        children: [FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])])
    let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
    let close = FakeAXNode(role: "AXButton", description: "close")
    let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
        close, viewBtn, FakeAXNode(role: "AXScrollArea", children: [table])])
    close.closesWindow = window
    let open = FakeAXNode(role: "AXButton", description: "open"); open.opensWindow = window
    let eqGroup = FakeAXNode(role: "AXGroup", description: "Tape", children: [open])
    let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
        FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"), eqGroup])
    let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
    let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [
        FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area])]))
    return (p, popup)
}

func testSetPluginOptionSelectsChoice() async throws {
    let (p, popup) = makeEnumProvider()
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    _ = try await d.axMixer.syncTracks()
    let r = try await SetPluginOptionTool(daemon: d).invoke([
        "track": .string("vox"), "slot": .int(0), "param": .string("Tape Type"), "choice": .string("Vintage")])
    guard case .object(let o) = r else { return XCTFail() }
    XCTAssertEqual(o["verified"], .bool(true))
    XCTAssertEqual(popup.stringValue, "Vintage")
}

func testSetPluginOptionUnknownChoiceListsChoices() async throws {
    let (p, _) = makeEnumProvider()
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    _ = try await d.axMixer.syncTracks()
    do {
        _ = try await SetPluginOptionTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Tape Type"), "choice": .string("Nope")])
        XCTFail("expected an unknown-choice ToolFailure")
    } catch let f as ToolFailure { XCTAssertTrue(f.expected?.contains("Vintage") ?? false) }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testSetPluginOption"`
Expected: FAIL — `SetPluginOptionTool` not defined.

- [ ] **Step 3: Add `selectEnumChoice` to `AXMenuDriver.swift`**

```swift
/// Select `choice` in an in-table enum AXPopUpButton by pressing it and walking its plain AXMenu.
/// Distinct from the SEARCH-driven catalog popups (selectRoutingDestination/selectPluginFromPopup):
/// an in-table enum is a small fixed list that opens a plain AXMenu of AXMenuItems (Task 0). Picks
/// the EXACT case-insensitive title match. Dismisses the popup (AXCancel) on any throw path. The
/// TOOL re-reads the popup's value afterwards as the independent oracle.
public func selectEnumChoice(from popup: AXHandle, choice: String) async throws {
    try? p.perform(.press, on: popup)                 // open it (return code unreliable — read the tree)
    try? await Task.sleep(for: .milliseconds(40))
    let items = menuItems(under: popup)
    guard let hit = items.first(where: {
        (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(choice) == .orderedSame
    }) else {
        try? p.perform(.cancel, on: popup)
        throw ToolFailure(error: "no choice '\(choice)'", layer: "ax",
                          expected: "one of: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))",
                          observed: "no match")
    }
    try p.perform(.press, on: hit)
}
```

(`menuItems(under:)` is the existing private helper — it flattens the `AXMenu` child into its `AXMenuItem`s.)

- [ ] **Step 4: Add `SetPluginOptionTool` to `PluginTools.swift` and register it**

```swift
public struct SetPluginOptionTool: LogicTool {
    public let name = "set_plugin_option"
    public let description = "Select a value in a plugin's enum parameter (an in-table popup) via Logic's Controls view, verified against the popup's displayed value. 'param': name (prefix ok) or integer index. 'choice': the exact option name."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("Parameter name (prefix ok) or integer index")]),
        "choice": .object(["type": .string("string"), "description": .string("The option name to select")]),
    ], required: ["slot", "param", "choice"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.coercedInt.map(String.init)
        guard let paramKey else { throw ToolFailure(error: "missing required argument 'param'", layer: "daemon") }
        let choice = try requireString(args, "choice", tool: name)

        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        guard !controls.isEmpty else {
            throw ToolFailure(error: "plugin exposes no addressable parameters", layer: "ax",
                              expected: "an addressable Controls-view parameter", observed: "opaque plugin")
        }
        let wanted = paramKey.lowercased()
        let target = controls.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in (0..<controls.count).contains(i) ? controls[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no parameter '\(paramKey)'", layer: "ax",
                              expected: controls.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard target.kind == .popup else {
            throw ToolFailure(error: "parameter '\(target.name)' is not an enum popup — use \(target.kind == .slider ? "set_plugin_param" : "press_plugin_control")",
                              layer: "ax", expected: "an enum popup parameter", observed: "kind \(target.kind.rawValue)")
        }
        try await daemon.menu.selectEnumChoice(from: target.handle, choice: choice)
        // Oracle: re-walk the table and confirm the popup now displays `choice`.
        let after = try await daemon.ax.controlTable(in: axEnterPluginControls(daemon, trackName: trackName, slot: slot).window)
        let now = after.first { $0.name == target.name }?.display ?? ""
        let verified = now.caseInsensitiveCompare(choice) == .orderedSame
        await daemon.journal.record(MixMutation(
            tool: "set_plugin_option", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(now)"))
        return .object(["param": .string(target.name), "display": .string(now), "verified": .bool(verified)])
    }
}
```

Register in `Daemon.swift` after `SetPluginParamTool`:

```swift
await registry.register(SetPluginOptionTool(daemon: self))
```

- [ ] **Step 5: Populate `choices` best-effort in `controlTable`**

In `AXBridge.controlTable`, for a `.popup` control, read statically-present menu items (some popups pre-expose them; if not, `choices` stays nil and `set_plugin_option`'s live walk is authoritative). Replace the `choices: nil` in the `PluginControl(...)` construction with:

```swift
let choices: [String]? = kind == .popup
    ? p.children(of: control).flatMap { m in p.string(.role, of: m) == "AXMenu" ? p.children(of: m) : [] }
        .compactMap { p.string(.title, of: $0) }.nonEmptyOrNil()
    : nil
```

Add a small helper in the same file (or inline the guard): `private extension Array { func nonEmptyOrNil() -> Array? { isEmpty ? nil : self } }`. If a `nonEmptyOrNil` already exists, reuse it.

- [ ] **Step 6: Run the enum tests, then the full suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testSetPluginOption"`
Expected: PASS (2/2).
Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/LogicMCPCore/AX/AXMenuDriver.swift Sources/LogicMCPCore/AX/AXBridge.swift Sources/LogicMCPCore/Tools/PluginTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "feat(ax): set_plugin_option — select in-table enum choices via Controls view"
```

---

## Task 4: `press_plugin_control` — press toggles & buttons

Add `PressPluginControlTool` for `.toggle` (`AXCheckBox`, press-only) and header buttons, verified by re-read. Extend the fake so `.press` flips a checkbox. Register the tool.

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Modify: `Tests/LogicMCPCoreTests/FakeAXTree.swift` (checkbox flip on press)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`

**Interfaces:**
- Consumes: `axEnterPluginControls`, `PluginControl` (`.toggle`), `AXBridge.press`, `AXBridge.controlTable`.
- Produces: `PressPluginControlTool` (`press_plugin_control`) returning `{param, display, verified}`.

- [ ] **Step 1: Extend the fake — `.press` on an `AXCheckBox` flips `"0"`⇄`"1"`**

In `FakeAXTree.swift`, in `perform(_:on:)`, add a case before the generic `.press`:

```swift
case .press where n.role == "AXCheckBox":
    n.stringValue = (n.stringValue == "1") ? "0" : "1"
```

(Place it alongside the existing `case .press where n.subrole == "AXSwitch":` flip; the generic `.press` window-open/close case stays for other roles.)

- [ ] **Step 2: Write the failing press test**

```swift
func testPressPluginControlTogglesCheckbox() async throws {
    let (p, _, _) = makeMixedKindProvider()          // rows: slider A, toggle B ("0"), slider C
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    _ = try await d.axMixer.syncTracks()
    let r = try await PressPluginControlTool(daemon: d).invoke([
        "track": .string("vox"), "slot": .int(0), "param": .string("B")])
    guard case .object(let o) = r else { return XCTFail() }
    XCTAssertEqual(o["display"], .string("1"), "the checkbox flipped 0→1")
    XCTAssertEqual(o["verified"], .bool(true))
}

func testPressPluginControlRejectsSlider() async throws {
    let (p, _, _) = makeMixedKindProvider()
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    _ = try await d.axMixer.syncTracks()
    do {
        _ = try await PressPluginControlTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("A")])
        XCTFail("expected a wrong-kind ToolFailure for a slider")
    } catch let f as ToolFailure { XCTAssertTrue(f.error.contains("set_plugin_param")) }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testPressPluginControl"`
Expected: FAIL — `PressPluginControlTool` not defined.

- [ ] **Step 4: Add `PressPluginControlTool` and register it**

```swift
public struct PressPluginControlTool: LogicTool {
    public let name = "press_plugin_control"
    public let description = "Press or toggle a plugin's non-knob control (an in-table checkbox, or a header button) by name, via Logic's Controls view. Verifies the new state where the control exposes one. Use set_plugin_param for sliders and set_plugin_option for enum popups."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "param": .object(["type": .string("string"), "description": .string("Control name (prefix ok) or integer index")]),
    ], required: ["slot", "param"])
    let daemon: Daemon

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let trackName = try requireString(args, "track", tool: name)
        guard let slot = args["slot"]?.coercedInt, (0...127).contains(slot) else {
            throw ToolFailure(error: "'slot' must be an integer in 0…127", layer: "daemon")
        }
        let paramKey = args["param"]?.stringValue ?? args["param"]?.coercedInt.map(String.init)
        guard let paramKey else { throw ToolFailure(error: "missing required argument 'param'", layer: "daemon") }

        let (name, _, controls) = try await axEnterPluginControls(daemon, trackName: trackName, slot: slot)
        guard !controls.isEmpty else {
            throw ToolFailure(error: "plugin exposes no addressable parameters", layer: "ax",
                              expected: "an addressable Controls-view control", observed: "opaque plugin")
        }
        let wanted = paramKey.lowercased()
        let target = controls.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? Int(paramKey).flatMap { i in (0..<controls.count).contains(i) ? controls[i] : nil }
        guard let target else {
            throw ToolFailure(error: "no control '\(paramKey)'", layer: "ax",
                              expected: controls.map(\.name).joined(separator: ", "), observed: "no match")
        }
        guard target.kind == .toggle else {
            throw ToolFailure(error: "control '\(target.name)' is a \(target.kind.rawValue) — use \(target.kind == .slider ? "set_plugin_param" : "set_plugin_option")",
                              layer: "ax", expected: "a pressable toggle/button", observed: "kind \(target.kind.rawValue)")
        }
        let before = target.display ?? ""
        try await daemon.ax.press(target.handle)
        // Oracle: re-walk and confirm the toggle's value changed.
        let after = try await daemon.ax.controlTable(in: axEnterPluginControls(daemon, trackName: trackName, slot: slot).window)
        let now = after.first { $0.name == target.name }?.display ?? ""
        await daemon.journal.record(MixMutation(
            tool: "press_plugin_control", track: name, undoArguments: nil,
            descriptionText: "\(name) \(target.name) → \(now)"))
        return .object(["param": .string(target.name), "display": .string(now), "verified": .bool(now != before)])
    }
}
```

Register in `Daemon.swift` after `SetPluginOptionTool`:

```swift
await registry.register(PressPluginControlTool(daemon: self))
```

- [ ] **Step 5: Run the press tests, then the full suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testPressPluginControl"`
Expected: PASS (2/2).
Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicMCPCore/Tools/PluginTools.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/FakeAXTree.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "feat(ax): press_plugin_control — toggle in-table checkboxes/buttons via Controls view"
```

---

## Task 5: Undo — self-journaled reverse-actuation for the three setters

Give the three setters real `undoArguments` so `undo_last` reverses them via our own journal — independent of whether the primitive registers a Logic undo entry (Task 0's undo finding only adds a doc note). This closes the smoke's "wrong-thing-undone" hazard: plugin writes are reversed by `undo_last`, never confused with `undo_structural`.

**Files:**
- Modify: `Sources/LogicMCPCore/Tools/PluginTools.swift` (all three setters)
- Modify: `Sources/LogicMCPCore/Tools/UndoTool.swift` (description string)
- Test: `Tests/LogicMCPCoreTests/AXPluginToolTests.swift`

**Interfaces:**
- Consumes: `UndoJournal.record(MixMutation(...))` — note `MixMutation.undoArguments` is **`[String: String]?`**, and `UndoLastTool` reconstructs `Value`s from it (numeric strings → number EXCEPT keys `track`/`bus`/`param` which stay strings; `"true"`/`"false"` → bool; else string). So every undo dict value is a `String`.
- Produces: `set_plugin_param`/`set_plugin_option`/`press_plugin_control` each record `undoArguments` that re-drive the control to its prior state; `UndoLastTool`'s description updated (plugin params ARE now restorable).

- [ ] **Step 1: Write the failing undo round-trip test**

```swift
/// A set_plugin_param followed by undo_last must return the slider to its prior display value,
/// via OUR journal (undo_last), not Logic's Edit▸Undo — the smoke's wrong-thing-undone hazard.
func testUndoLastReversesSetPluginParam() async throws {
    let (p, bass) = makeConvergingProvider()         // display = raw/100 %, starts at 0 %
    p.nudgeMode = false
    let d = await Daemon(wire: InMemoryWire(), axProvider: p)
    let registry = ToolRegistry(); await d.registerAllTools(in: registry)
    _ = try await d.axMixer.syncTracks()
    _ = try await SetPluginParamTool(daemon: d).invoke([
        "track": .string("vox"), "slot": .int(0), "param": .string("Bass"), "value": .string("25 %")])
    XCTAssertEqual(try XCTUnwrap(bass.numberValue), 2500, accuracy: 1)
    _ = try await UndoLastTool(daemon: d, registry: registry).invoke(["n": .int(1)])
    XCTAssertEqual(try XCTUnwrap(bass.numberValue), 0, accuracy: 1, "undo_last re-drove the slider to its prior 0 %")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testUndoLastReversesSetPluginParam"`
Expected: FAIL — the slider stays at 2500 (`undoArguments: nil` → undo_last skips it).

- [ ] **Step 3: Capture prior state and record `undoArguments` in `set_plugin_param`**

In `SetPluginParamTool.invoke`, capture the prior display BEFORE converging (it's on the resolved control), and record it as the undo target. Replace the `undoArguments: nil` record with:

The undo dict is **`[String: String]`** (MixMutation's type), values as strings:

```swift
let priorDisplay = target.display ?? ""
let undoable = PluginDisplay.parse(priorDisplay).number != nil   // only if the prior reads back as a number+unit
// … (existing converge code producing `display` and `verified`) …
await daemon.journal.record(MixMutation(
    tool: "set_plugin_param", track: name,
    undoArguments: undoable ? ["track": name, "slot": String(slot),
                               "param": target.name, "value": priorDisplay] : nil,
    descriptionText: "\(name) \(target.name) → \(display)"))
```

`undo_last` replays `set_plugin_param` with `value: priorDisplay` (a unit string like `"0 %"` — `UndoLastTool` keeps it a string because `Double("0 %")` is nil), re-converging the slider back. Guarding on `undoable` means a prior with no parseable number is skipped (nil) rather than replayed into an error.

- [ ] **Step 4: Record `undoArguments` for the other two setters (also `[String: String]`) + update the undo_last description**

`set_plugin_option`: undo re-selects the prior choice — `undoArguments: ["track": name, "slot": String(slot), "param": target.name, "choice": priorChoice]` where `priorChoice = target.display ?? ""` captured before the select.

`press_plugin_control`: a toggle is involutive — undo is another press of the same control — `undoArguments: ["track": name, "slot": String(slot), "param": target.name]`.

In `Sources/LogicMCPCore/Tools/UndoTool.swift`, update the now-outdated description (it claims "Plugin-param changes cannot be deterministically restored and are reported as skipped"):

```swift
public let description = "Undo the last n mix mutations made through this daemon by restoring their prior values. Plugin params/options/toggles are re-driven to their prior state via the Controls view; a mutation with no recorded prior is reported as skipped."
```

- [ ] **Step 5: Run the undo test, then the full suite**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter "AXPluginToolTests/testUndoLastReversesSetPluginParam"`
Expected: PASS.
Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicMCPCore/Tools/PluginTools.swift Tests/LogicMCPCoreTests/AXPluginToolTests.swift
git commit -m "feat(ax): plugin-param writes reverse via undo_last (self-journaled, not undo_structural)"
```

---

## Task 6: Live smoke — the ship gate (real Logic, third-party write required)

No TDD — the phase's done-criteria: a live, verified write on a third-party plugin, plus stock param/enum/toggle and clean undo, no focus stolen. Documented checklist (like Plan 1's smoke), recorded in `docs/integration-smoke.md` and `.superpowers/sdd/progress.md`.

**Files:**
- Modify: `docs/integration-smoke.md` (append a `--plugins` write-path section).

- [ ] **Step 1: Build, reconnect, confirm the primitive default matches Task 0**

```bash
swift build 2>&1 | tail -3
# In the MCP client: /mcp reconnect, then `ping` → expect stale:false.
# Confirm AXBridge.defaultSliderActuation == the primitive Task 0 proved.
```

- [ ] **Step 2: Stock slider write, verified against the display oracle**

Set the Channel EQ Low Shelf Gain to `-3 dB` (the exact case that railed in Plan 1) by unit AND by normalized value:

```
set_plugin_param(track:"vox", slot:0, param:"Low Shelf Gain", value:"-3 dB")   → verified:true, display "-3.0 dB"
set_plugin_param(track:"vox", slot:0, param:"Low Shelf Gain", value:0.5)         → lands mid-range, verified:true
```

Confirm no focus stolen (frontmost stays the terminal/client throughout).

- [ ] **Step 3: Enum select + toggle press on a stock plugin**

```
set_plugin_option(track:…, slot:…, param:<enum>, choice:<value>)   → verified:true, display == choice
press_plugin_control(track:…, slot:…, param:<toggle>)               → verified:true, display flipped
```

- [ ] **Step 4: THIRD-PARTY verified write (the ship gate)**

Insert a third-party plugin (UAD or SketchCassette) on a scratch strip, open it, and set one slider param by unit:

```
insert_plugin(track:<scratch>, name:"SketchCassette II")   # or a UAD plugin
set_plugin_param(track:<scratch>, slot:<n>, param:<a named slider>, value:<unit target>)
# REQUIRED: verified:true against that plugin's display string. This gates the merge.
```

- [ ] **Step 5: Undo cleanliness + net-zero**

```
undo_last(n:1)   # reverses the third-party param write via our journal
undo_structural  # (×N) removes the scratch insert; confirm it does NOT touch a plugin param
```

Confirm the `undo_structural` guard held (it undid the insert, not a param), the project is net-zero, and focus was never stolen.

- [ ] **Step 6: Record results and append the checklist doc**

Append the above as a `## Plugin write-path smoke (--plugins)` section in `docs/integration-smoke.md`, record the outcome (pass/fail per step, the third-party plugin used, the converged values) in `.superpowers/sdd/progress.md`, and commit:

```bash
git add docs/integration-smoke.md
git commit -m "docs(smoke): plugin write-path checklist + live third-party write result"
```

The merge decision (this branch → `main`) is the user's, gated on Step 4 passing.

---

## Self-Review

**Spec coverage** (against `2026-07-17-plugin-write-path-actuation-design.md`):
- Adaptive converger (binary-search / step, display oracle, direction/polarity, honest stall) → Task 1; rewired into `set_plugin_param` → Task 2. ✓
- `set_plugin_option` (enum popups, plain-menu vs search per Task 0) → Task 3. ✓
- `press_plugin_control` (checkbox/button, press-only) → Task 4. ✓
- Probe-gated actuation + undo decision → Task 0 records both; converger default in Task 1; undo self-journal in Task 5 (robust regardless of the undo finding). ✓
- Unconditional `undo_structural` guard → Task 5 (plugin writes reverse via `undo_last`, never recorded on the structural path). ✓
- Error handling (kind mismatch, choice-not-found, opaque) → Tasks 2/3/4 (kind guards + existing opaque guard). ✓
- Testing (fixture-parsing + fake converger + undo round-trip) → Tasks 0/1/2/3/4/5. ✓
- Done-criteria: stock param by unit+normalized, enum, toggle, THIRD-PARTY verified write, clean undo, no focus stolen → Task 6. ✓

**Placeholder scan:** No TBD/TODO. The `defaultSliderActuation` value and the `selectEnumChoice` mechanism are explicit execution-time selections driven by Task 0's recorded finding, not placeholders (the code is complete and compiles either way).

**Type consistency:** `SliderActuation` / `convergeAdaptive` (Task 1) are consumed unchanged in Task 2. `PluginControl.{kind,handle,display,choices}` used consistently across Tasks 2–5. Tool result shape `{param, display, verified}` uniform across the three setters. `undoArguments` dictionaries use the same arg names the tools' `invoke` reads (`track`/`slot`/`param`/`value`/`choice`).
