# AX Structural Ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent no-focus, self-verified **structural control of Logic Pro** — create/delete/rename/select tracks, insert plugins, set output routing, and snapshot the project — driven by `AXPress` on menu items, popups, and dialogs, verified by re-reading through the Phase 2 AX layer.

**Architecture:** Extend the Phase 2 `AXProvider` seam with menu-bar access, string-set, and show-menu/cancel actions, then add one new actor `AXMenuDriver` (menu-path press, popup drive, dialog fill) behind that same seam. Structure tools call `AXMenuDriver` to act and reuse `AXBridge`/`AXMixer` to verify (act → re-read → confirm). `checkpoint` + auto-checkpoint-before-`delete_track` is the safety spine.

**Tech Stack:** Swift 6, `ApplicationServices` (`AXUIElement`), swift-mcp-sdk, swift-argument-parser, XCTest. Builds on merged Phase 2 (`AXProvider`/`SystemAXProvider`/`FakeAXProvider`, `AXBridge`, `AXMixer`, `Daemon`, `logic-mcp axdump`/`smoke`).

## Global Constraints

- **Platform:** macOS 14+, Swift tools 6.0 (do not change `Package.swift`).
- **No-focus invariant:** no code may activate Logic or set `kAXFrontmost`/`AXMain`. The menu probe proved menu/popup/dialog `AXPress` works with Logic backgrounded. Unit tests assert the provider is never asked to activate.
- **Verified ground truth:** every structural tool returns state re-read from AX after the action (via `AXMixer`/`AXBridge`); on mismatch it throws `ToolFailure`. Never fabricate.
- **Structured errors only:** `ToolFailure(error:layer:expected:observed:)`, `layer:"ax"` for AX failures, `"daemon"` for bad arguments.
- **Selectors key on `role` + menu-item **title** / control **description**, NEVER on `AXIdentifier`** (unstable `_NS:`-style ids).
- **Safety:** `delete_track` (the only destructive tool) auto-checkpoints first and refuses if it cannot snapshot.
- **Test hygiene (from HANDOFF):** hard-timeout every test run — `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test …`. Retain fakes (never `_ =`).
- **Real-Logic tests are net-zero:** create-then-delete, clean up any checkpoint copy; run on the `mcp_test` scratch project, Logic backgrounded. Only ONE process holds the virtual MIDI port, but `axdump`/AX tools don't use it.
- **`AXBridge` and `AXMenuDriver` are actors:** every call to their methods from tool code needs `await` (e.g. `await daemon.ax.control(...)`, `try await daemon.menu.pressMenuPath(...)`). The code blocks below are illustrative — add `await`/`try` exactly as the Swift 6 compiler requires, and confirm each Phase-2 method's real signature in `Sources/LogicMCPCore/AX/` before calling it (esp. `AXMixer.syncTracks()`'s return type, and that `AXBridge.control`/`read`/`pluginGroups`/`outputButtonHandle` are actor-isolated).
- **Probe-dependency (Phase 2 pattern):** menu-item titles (incl. trailing `…`), the checkpoint mechanism, the rename-field settability, the output popup titles, and the plugin-insert path are all captured as fixtures in Task 1 and used verbatim by later tasks. Where a task says "per the fixture / whichever Task 1 found", that is a real branch to resolve from the captured file — not a placeholder to invent.

---

## File structure

**New (Sources/LogicMCPCore/AX/):**
- `AXMenuDriver.swift` — the actor: `pressMenuPath`, `selectPopupItem`, dialog helpers (`frontSheet`, `setField`, `pressButton`).

**New (Sources/LogicMCPCore/Tools/):**
- `StructureTools.swift` — `create_track`, `delete_track`, `rename_track`, `select_track`, `set_output`, `checkpoint` tools.
- `PluginInsertTool.swift` — `insert_plugin` (kept separate; popup/search navigation is the most involved).

**New (Tests/LogicMCPCoreTests/):**
- `AXMenuDriverTests.swift`, `StructureToolTests.swift`, `PluginInsertToolTests.swift`.
- `Fixtures/ax/` additions: `menu_track.txt`, `menu_file.txt`, `dialog_new_tracks.txt`, `popup_output.txt`, `popup_plugin.txt` (captured in Task 1).

**Modified:**
- `Sources/LogicMCPCore/AX/AXProvider.swift` — add `menuBar()`, `setString(_:of:)`; add `.showMenu`/`.cancel` to `AXAction`.
- `Sources/LogicMCPCore/AX/SystemAXProvider.swift` — implement the new provider methods.
- `Tests/LogicMCPCoreTests/FakeAXTree.swift` — model a menu bar, `setString`, an `onPress` hook.
- `Sources/LogicMCPCore/Daemon.swift` — hold `menu: AXMenuDriver`; register the structure tools.
- `Sources/logic-mcp/AXDump.swift` — add `menu <name>` mode.

---

## Task 1: Extend `axdump` with a `menu` mode; capture menu/dialog/popup fixtures; resolve `checkpoint` viability

Design-shaping first task (Phase 2's fixture-capture pattern). **Requires real Logic** with `mcp_test`; the host terminal holds Accessibility. The implementer writes the `axdump menu` code; the **controller captures the fixtures and resolves checkpoint** against real Logic (opening dialogs/popups is UI-mutating and must be driven live).

**Files:**
- Modify: `Sources/logic-mcp/AXDump.swift`
- Create (captured, committed): `Tests/LogicMCPCoreTests/Fixtures/ax/menu_track.txt`, `menu_file.txt`, `dialog_new_tracks.txt`, `popup_output.txt`, `popup_plugin.txt`

- [ ] **Step 1: Add a `menu` mode to `axdump`** (`Sources/logic-mcp/AXDump.swift`)

Add to the `switch mode` block a case that dumps a top-level menu's items (read-only; menus are statically readable):

```swift
        case "menu":
            guard args.count >= 2 else { print("usage: axdump menu <Track|File|Mix|Edit>"); return }
            guard let mb = p.menuBar() else { print("no menu bar"); return }
            let name = args[1]
            guard let item = p.children(of: mb).first(where: { p.string(.title, of: $0) == name }) else {
                print("menu '\(name)' not found"); return
            }
            // AXMenuBarItem → AXMenu → AXMenuItems
            for sub in p.children(of: item) { dump(p, sub, depth: 0, maxDepth: 3) }
```

Update the `@Argument` help to mention `menu <name>`. (Requires `menuBar()` on the provider — Task 2 adds it; if doing Task 1 first, add the two-line `menuBar()` from Task 2 Step 1 to `SystemAXProvider` now so this compiles.)

- [ ] **Step 2: Build**

Run: `perl -e 'alarm 600; exec @ARGV' swift build`
Expected: builds clean.

- [ ] **Step 3: (CONTROLLER) Capture menu fixtures**

```bash
.build/debug/logic-mcp axdump menu Track > Tests/LogicMCPCoreTests/Fixtures/ax/menu_track.txt
.build/debug/logic-mcp axdump menu File  > Tests/LogicMCPCoreTests/Fixtures/ax/menu_file.txt
```
Record the exact titles of: `New Audio Track`, `New Software Instrument Track`, `New Tracks…`, `Rename Track`, `Delete Track` (Track); `Project Alternatives` and its children (File). Note trailing `…` and any non-ASCII exactly — the driver matches on title.

- [ ] **Step 4: (CONTROLLER) Resolve `checkpoint` viability** — the #1 risk

Drive `File → Project Alternatives → New Alternative…` on a SCRATCH copy of `mcp_test`:
- If `Project Alternatives` is enabled and `New Alternative…` opens a name sheet → checkpoint via alternatives is viable; capture the sheet's field + button titles.
- If it stays disabled → fall back: capture the `Save A Copy As…` sheet (filename field + Save button). Record which mechanism Task 5 will implement.
Write the decision + the sheet layout into `dialog_new_tracks.txt`'s header comment (or a `checkpoint.txt` fixture) so Task 5 has exact selectors.

- [ ] **Step 5: (CONTROLLER) Capture dialog + popup fixtures**

- `New Tracks…` sheet: trigger it, `axdump tree`, locate the sheet, record the format radios/checkboxes, the count stepper, the name field (is it AXValue-**settable**? note it), and the `Create` button title. Save to `dialog_new_tracks.txt`.
- Output-routing popup: on a strip, `AXShowMenu`/press the output button, `axdump tree`, record the bus/output item titles + submenu shape. Save to `popup_output.txt`. Dismiss (Escape).
- Plugin-insert popup: press the strip's `audio plug-in` button, record the category→plugin menu shape; ALSO capture `Mix → Search and Add Plug-in…` (search field + result list). Save to `popup_plugin.txt` and note which path is more reliably title-addressable (decides Task 8).

- [ ] **Step 6: Commit** (controller commits code + fixtures)

```bash
git add Sources/logic-mcp/AXDump.swift Tests/LogicMCPCoreTests/Fixtures/ax/
git commit -m "feat(ax): axdump menu mode; capture Phase 3 menu/dialog/popup fixtures + checkpoint decision"
```

---

## Task 2: Extend `AXProvider`; add `AXMenuDriver.pressMenuPath`

**Files:**
- Modify: `Sources/LogicMCPCore/AX/AXProvider.swift`, `SystemAXProvider.swift`
- Modify: `Tests/LogicMCPCoreTests/FakeAXTree.swift`
- Create: `Sources/LogicMCPCore/AX/AXMenuDriver.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift`
- Test: `Tests/LogicMCPCoreTests/AXMenuDriverTests.swift`

**Interfaces:**
- Consumes: `AXProvider`, `AXHandle`, `AXAttr`, `AXAction`, `ToolFailure`.
- Produces:
  - `AXProvider.menuBar() -> AXHandle?`, `AXProvider.setString(_ s: String, of h: AXHandle) throws`
  - `AXAction.showMenu = "AXShowMenu"`, `AXAction.cancel = "AXCancel"`
  - `actor AXMenuDriver { init(provider: AXProvider); func pressMenuPath(_ path: [String]) async throws; func frontSheet() -> AXHandle?; func descendant(of:role:title:) -> AXHandle?; func setField(in sheet: AXHandle, title: String, to value: String) throws; func pressButton(in sheet: AXHandle, title: String) throws; func selectPopupItem(from control: AXHandle, path: [String]) async throws }`

- [ ] **Step 1: Extend the provider protocol** (`AXProvider.swift`)

Add the two `AXAction` cases and two protocol methods:

```swift
public enum AXAction: String {
    case press = "AXPress", increment = "AXIncrement", decrement = "AXDecrement"
    case showMenu = "AXShowMenu", cancel = "AXCancel"
}
```
```swift
    func menuBar() -> AXHandle?
    func setString(_ s: String, of h: AXHandle) throws
```

- [ ] **Step 2: Implement in `SystemAXProvider`** (`SystemAXProvider.swift`)

```swift
    public func menuBar() -> AXHandle? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &v) == .success,
              let mb = v else { return nil }
        return AXHandle(system: mb as! AXUIElement)
    }
    public func setString(_ s: String, of h: AXHandle) throws {
        let r = AXUIElementSetAttributeValue(raw(h), kAXValueAttribute as CFString, s as CFString)
        if r != .success { throw AXUnavailable() }
    }
```
(`app` is optional in `SystemAXProvider` after Phase 2's Task-3 change — guard it: if nil, `menuBar()` returns nil and `setString` throws `AXUnavailable`. Match the existing nil-app handling in that file.)

- [ ] **Step 3: Extend `FakeAXProvider`** (`FakeAXTree.swift`)

Add a menu-bar root, `setString`, and an `onPress` hook so a pressed menu item can mutate the fake tree (models "New Audio Track adds a strip"):

```swift
    // FakeAXNode: add
    var onPress: (() -> Void)?
    // (also allow a mutable stringValue setter — stringValue is already a var)

    // FakeAXProvider: add a menuBarRoot stored property (optional), set via init or a helper,
    // and:
    func menuBar() -> AXHandle? { menuBarNode.map { AXHandle(fake: $0) } }
    func setString(_ s: String, of h: AXHandle) throws {
        guard let n = node(h) else { throw AXUnavailable() }
        n.stringValue = s
    }
    // in perform(_:on:), for .press, after any existing switch behavior, also fire:
    //     node(h)?.onPress?()
    // (keep the AXSwitch flip + window open/close behavior already there)
```
Add a `makeMenuBar(_ items:)` test helper that builds `AXMenuBar → AXMenuBarItem(title) → AXMenu → AXMenuItem(title, onPress:)`.

- [ ] **Step 4: Write the failing `AXMenuDriver` test** (`AXMenuDriverTests.swift`)

```swift
import XCTest
@testable import LogicMCPCore

final class AXMenuDriverTests: XCTestCase {
    /// A menu bar with Track → New Audio Track (whose press sets a flag).
    func providerPressingSetsFlag(_ flag: Flag) -> FakeAXProvider {
        let item = FakeAXNode(role: "AXMenuItem", title: "New Audio Track")
        item.onPress = { flag.value = true }
        let menu = FakeAXNode(role: "AXMenu", children: [item])
        let track = FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])
        let bar = FakeAXNode(role: "AXMenuBar", children: [track])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication"))
        p.menuBarNode = bar
        return p
    }
    final class Flag { var value = false }

    func testPressMenuPathPressesLeafItem() async throws {
        let flag = Flag()
        let driver = AXMenuDriver(provider: providerPressingSetsFlag(flag))
        try await driver.pressMenuPath(["Track", "New Audio Track"])
        XCTAssertTrue(flag.value)
    }

    func testPressMenuPathUnknownItemThrows() async throws {
        let driver = AXMenuDriver(provider: providerPressingSetsFlag(Flag()))
        do { try await driver.pressMenuPath(["Track", "Nope"]); XCTFail("expected throw") }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "ax") }
    }
}
```

- [ ] **Step 5: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMenuDriverTests`
Expected: FAIL — `cannot find 'AXMenuDriver' in scope`.

- [ ] **Step 6: Write `AXMenuDriver`** (`AXMenuDriver.swift`)

```swift
import Foundation

/// Drives Logic's menus, popups, and dialogs by AXPress — the structural-ops actuator.
/// Behind the same `AXProvider` seam as `AXBridge`, so it is FakeAXTree-testable. Keys on
/// menu-item TITLE (stable, human-facing), never AXIdentifier. NEVER activates Logic.
public actor AXMenuDriver {
    private let p: AXProvider
    public init(provider: AXProvider) { self.p = provider }

    /// Descend the menu bar by title path and press the leaf. An `AXMenuBarItem`'s child is an
    /// `AXMenu` whose children are `AXMenuItem`s (some with nested `AXMenu` children).
    public func pressMenuPath(_ path: [String]) async throws {
        guard let bar = p.menuBar() else {
            throw ToolFailure(error: "no menu bar", layer: "ax",
                              expected: "Logic's menu bar", observed: "AXMenuBar unavailable")
        }
        var current = bar
        for (i, title) in path.enumerated() {
            let isLast = i == path.count - 1
            // Children of a bar/item are AXMenu(s); match the AXMenuItem/AXMenuBarItem by title.
            let candidates = menuItems(under: current)
            guard let match = candidates.first(where: {
                (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw ToolFailure(error: "menu item '\(title)' not found", layer: "ax",
                                  expected: "menu path \(path.joined(separator: " ▸ "))",
                                  observed: "available: \(candidates.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
            }
            if isLast {
                try p.perform(.press, on: match)
            } else {
                // Open the submenu so its items populate, then descend into it.
                try? p.perform(.press, on: match)
                try? await Task.sleep(for: .milliseconds(30))
                current = match
            }
        }
    }

    /// The AXMenuItems reachable one level under a bar item / menu item (through its AXMenu child).
    private func menuItems(under h: AXHandle) -> [AXHandle] {
        p.children(of: h).flatMap { child -> [AXHandle] in
            let role = p.string(.role, of: child)
            if role == "AXMenu" { return p.children(of: child) }
            if role == "AXMenuItem" || role == "AXMenuBarItem" { return [child] }
            return []
        }
    }

    /// Depth-first find by role and/or title (for dialogs/popups).
    public func descendant(of h: AXHandle, role: String? = nil, title: String? = nil) -> AXHandle? {
        func rec(_ x: AXHandle, _ d: Int) -> AXHandle? {
            if d > 12 { return nil }
            let rOK = role == nil || p.string(.role, of: x) == role
            let tOK = title == nil || (p.string(.title, of: x)?.caseInsensitiveCompare(title!) == .orderedSame)
            if (role != nil || title != nil), rOK, tOK { return x }
            for c in p.children(of: x) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.children(of: h).lazy.compactMap { rec($0, 0) }.first
    }

    /// The front-most sheet/dialog window (an AXSheet, or an AXWindow with a default button).
    public func frontSheet() -> AXHandle? {
        for w in p.windows() {
            if p.string(.subrole, of: w) == "AXDialog" || p.string(.subrole, of: w) == "AXSystemDialog" { return w }
            if descendant(of: w, role: "AXSheet", title: nil) != nil { return descendant(of: w, role: "AXSheet", title: nil) }
        }
        // Fallback: a top-level AXSheet.
        return p.windows().first { p.string(.role, of: $0) == "AXSheet" }
    }

    public func setField(in container: AXHandle, title: String, to value: String) throws {
        guard let field = descendant(of: container, role: "AXTextField", title: title)
            ?? descendant(of: container, role: "AXTextField", title: nil) else {
            throw ToolFailure(error: "no text field '\(title)' in dialog", layer: "ax",
                              expected: "a settable text field", observed: "none")
        }
        try p.setString(value, of: field)
    }

    public func pressButton(in container: AXHandle, title: String) throws {
        guard let btn = descendant(of: container, role: "AXButton", title: title) else {
            throw ToolFailure(error: "no '\(title)' button in dialog", layer: "ax",
                              expected: "a button titled '\(title)'", observed: "none")
        }
        try p.perform(.press, on: btn)
    }

    /// Open a popup on `control` (AXShowMenu, else AXPress), descend the item title `path`, press
    /// the leaf. On any miss, dismiss the popup (AXCancel) so nothing is left hanging.
    public func selectPopupItem(from control: AXHandle, path: [String]) async throws {
        do { try p.perform(.showMenu, on: control) } catch { try? p.perform(.press, on: control) }
        try? await Task.sleep(for: .milliseconds(40))
        var current = control
        for (i, title) in path.enumerated() {
            let items = menuItems(under: current)
            guard let match = items.first(where: {
                (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(title) == .orderedSame
            }) else {
                try? p.perform(.cancel, on: control)
                throw ToolFailure(error: "popup item '\(title)' not found", layer: "ax",
                                  expected: path.joined(separator: " ▸ "),
                                  observed: "available: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
            }
            if i == path.count - 1 { try p.perform(.press, on: match) }
            else { try? p.perform(.press, on: match); try? await Task.sleep(for: .milliseconds(30)); current = match }
        }
    }
}
```

- [ ] **Step 7: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter AXMenuDriverTests`
Expected: PASS.

- [ ] **Step 8: Wire into `Daemon`** (`Daemon.swift`)

Add `public let menu: AXMenuDriver` and in `init`, after `ax = …`: `menu = AXMenuDriver(provider: axProvider)`.

- [ ] **Step 9: Full suite + commit**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift build && perl -e 'alarm 600; exec @ARGV' swift test`
Expected: all prior + new pass.

```bash
git add Sources/LogicMCPCore/AX/AXProvider.swift Sources/LogicMCPCore/AX/SystemAXProvider.swift Sources/LogicMCPCore/AX/AXMenuDriver.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/FakeAXTree.swift Tests/LogicMCPCoreTests/AXMenuDriverTests.swift
git commit -m "feat(ax): AXMenuDriver + provider menu-bar/setString/showMenu extensions"
```

---

## Task 3: `create_track` (direct kinds) + `select_track`

**Files:**
- Create: `Sources/LogicMCPCore/Tools/StructureTools.swift`
- Modify: `Sources/LogicMCPCore/Daemon.swift` (register)
- Test: `Tests/LogicMCPCoreTests/StructureToolTests.swift`

**Interfaces:**
- Consumes: `AXMenuDriver.pressMenuPath`, `AXMixer.syncTracks`, `ProjectModel`, `AXBridge`.
- Produces: `CreateTrackTool`, `SelectTrackTool` (LogicTool conformers).

Menu titles from Task 1's `menu_track.txt` — use them VERBATIM (note trailing `…`). Below assumes `New Audio Track` / `New Software Instrument Track`.

- [ ] **Step 1: Write the failing test** (`StructureToolTests.swift`)

```swift
import XCTest
import MCP
@testable import LogicMCPCore

final class StructureToolTests: XCTestCase {
    /// Menu bar + a mixer area; pressing "New Audio Track" appends an "Audio 1" strip to the area,
    /// so create_track's verify (AXMixer.syncTracks) sees it.
    func provider() -> FakeAXProvider {
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"),
        ])
        let window = FakeAXNode(role: "AXWindow", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let newAudio = FakeAXNode(role: "AXMenuItem", title: "New Audio Track")
        newAudio.onPress = {
            area.children.append(FakeAXNode(role: "AXLayoutItem", description: "Audio 1"))
        }
        let menu = FakeAXNode(role: "AXMenu", children: [newAudio])
        p.menuBarNode = FakeAXNode(role: "AXMenuBar",
            children: [FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])])
        return p
    }
    func daemon(_ p: FakeAXProvider) async -> Daemon { await Daemon(wire: InMemoryWire(), axProvider: p) }

    func testCreateAudioTrackAppearsInMixer() async throws {
        let d = await daemon(provider())
        let r = try await CreateTrackTool(daemon: d).invoke(["kind": .string("audio")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["created"], .bool(true))
        let names = await d.model.snapshot.tracks.map(\.name)
        XCTAssertTrue(names.contains("Audio 1"), "new strip should appear on re-read")
    }

    func testCreateUnknownKindErrors() async throws {
        let d = await daemon(provider())
        do { _ = try await CreateTrackTool(daemon: d).invoke(["kind": .string("banjo")]); XCTFail() }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "daemon") }
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests`
Expected: FAIL — `cannot find 'CreateTrackTool'`.

- [ ] **Step 3: Write the tools** (`StructureTools.swift`)

```swift
import MCP

public struct CreateTrackTool: LogicTool {
    public let name = "create_track"
    public let description = "Create a new track. kind: 'audio' | 'software-instrument' | 'midi'. Optional name renames it after creation. Verified by re-reading the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "kind": .object(["type": .string("string"), "enum": .array([.string("audio"), .string("software-instrument"), .string("midi")])]),
            "name": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("kind")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let kind = try requireString(args, "kind", tool: name)
        // Menu titles are captured verbatim in Fixtures/ax/menu_track.txt.
        let item: String
        switch kind {
        case "audio": item = "New Audio Track"
        case "software-instrument": item = "New Software Instrument Track"
        case "midi": item = "New External MIDI Track"
        default: throw ToolFailure(error: "kind must be audio | software-instrument | midi", layer: "daemon")
        }
        let before = Set(try await currentTrackNames(daemon))
        try await daemon.menu.pressMenuPath(["Track", item])
        // Verify: a new strip appeared.
        let after = try await currentTrackNames(daemon)
        guard let created = after.first(where: { !before.contains($0) }) else {
            throw ToolFailure(error: "track creation not confirmed", layer: "ax",
                              expected: "a new strip after '\(item)'", observed: "mixer unchanged")
        }
        var finalName = created
        if let want = args["name"]?.stringValue, want != created {
            _ = try? await renameTrackAX(daemon, from: created, to: want)
            finalName = (try await currentTrackNames(daemon)).contains(want) ? want : created
        }
        return .object(["created": .bool(true), "track": .string(finalName), "kind": .string(kind)])
    }
}

public struct SelectTrackTool: LogicTool {
    public let name = "select_track"
    public let description = "Select a track by name (case-insensitive; unique prefix ok)."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(name)
        // Selecting = pressing the strip's name field / header. Confirm via the resolved name.
        try await daemon.menu.pressElement(strip)   // see helper below
        let resolved = await daemon.ax.read(strip).name
        return .object(["selected": .string(resolved)])
    }
}

// Shared helpers used across structure tools.
func currentTrackNames(_ daemon: Daemon) async throws -> [String] {
    try await daemon.axMixer.syncTracks()
}
```

Add a tiny `pressElement` convenience to `AXMenuDriver` (Task 2 file) so `select_track` can press an arbitrary element:
```swift
    public func pressElement(_ h: AXHandle) async throws { try p.perform(.press, on: h) }
```
And a `renameTrackAX` free function (defined in Task 4; if Task 3 lands first, add the stub that throws `ToolFailure(error:"rename not yet implemented",layer:"ax")` and fill it in Task 4).

**NOTE for the implementer:** `AXMixer.syncTracks()` returns `[String]` (the names) — confirm its exact signature in `Sources/LogicMCPCore/AX/AXMixer.swift` and match it; `currentTrackNames` wraps it.

- [ ] **Step 4: Run — passes**

Run: `pkill -f xctest 2>/dev/null; perl -e 'alarm 600; exec @ARGV' swift test --filter StructureToolTests`
Expected: PASS.

- [ ] **Step 5: Register + full suite + commit**

Register `CreateTrackTool`/`SelectTrackTool` in `Daemon.registerAllTools`. Run the full suite.
```bash
git add Sources/LogicMCPCore/Tools/StructureTools.swift Sources/LogicMCPCore/AX/AXMenuDriver.swift Sources/LogicMCPCore/Daemon.swift Tests/LogicMCPCoreTests/StructureToolTests.swift
git commit -m "feat(ax): create_track (direct kinds) + select_track via AXMenuDriver"
```

---

## Task 4: `rename_track`

**Files:** Modify `StructureTools.swift`, `StructureToolTests.swift`.

Rename path depends on Task 1's finding — whether the strip's `AXTextField desc="name"` is AXValue-**settable**. Task 1 recorded it. Implement accordingly:

- [ ] **Step 1: Test** (append to `StructureToolTests.swift`) — pressing rename sets the name field, then re-read shows the new name. Build a fake strip whose name field's `setString` updates its description-return path (model the fake so `read().name` reflects the set).

```swift
    func testRenameTrackUpdatesName() async throws {
        // fake: strip "vox" with a settable name field; rename to "lead vox"
        let p = providerWithRenamableStrip("vox")
        let d = await daemon(p)
        _ = try await d.axMixer.syncTracks()
        let r = try await RenameTrackTool(daemon: d).invoke(["name": .string("vox"), "to": .string("lead vox")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("lead vox"))
    }
```
(Build `providerWithRenamableStrip` so the `AXLayoutItem`'s `description` is driven by a child name field's `stringValue` — or, simpler, model rename as setting the `AXLayoutItem`'s own description. Match whatever Task 1 says the real mechanism is; keep the test faithful to it.)

- [ ] **Step 2: Run — fails.** `RenameTrackTool` undefined.

- [ ] **Step 3: Implement `RenameTrackTool` + `renameTrackAX`** (`StructureTools.swift`)

```swift
public struct RenameTrackTool: LogicTool {
    public let name = "rename_track"
    public let description = "Rename a track. Verified by re-reading the strip name."
    public let inputSchema = trackArgSchema(["to": .object(["type": .string("string")])], required: ["to"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let from = try requireString(args, "track", tool: name)
        let to = try requireString(args, "to", tool: name)
        let final = try await renameTrackAX(daemon, from: from, to: to)
        return .object(["track": .string(final)])
    }
}

/// Rename via the strip's name AXTextField (set-value) IF settable (Task 1 records this); else the
/// `Track ▸ Rename Track` menu path. Verifies by re-reading. Returns the confirmed final name.
func renameTrackAX(_ daemon: Daemon, from: String, to: String) async throws -> String {
    let strip = try await daemon.ax.find(from)
    guard let nameField = daemon.ax.control(strip, description: "name") else {
        throw ToolFailure(error: "no name field on '\(from)'", layer: "ax",
                          expected: "the strip name field", observed: "none")
    }
    if await daemon.ax.isSettable(nameField) {
        try await daemon.ax.setValueString(to, of: nameField)   // add this passthrough to AXBridge
    } else {
        // Fallback: select then Track ▸ Rename Track (opens an inline edit). Title from menu_track.txt.
        try await daemon.menu.pressElement(strip)
        try await daemon.menu.pressMenuPath(["Track", "Rename Track"])
        // The rename control is now an editable field on the strip; set it.
        try await daemon.ax.setValueString(to, of: nameField)
    }
    _ = try await daemon.axMixer.syncTracks()
    let ok = (try await daemon.ax.find(to))   // throws if not found ⇒ rename unconfirmed
    _ = ok
    return to
}
```
Add to `AXBridge` (Task-2-adjacent; it already wraps the provider): `public func setValueString(_ s: String, of h: AXHandle) throws { try p.setString(s, of: h) }`.

- [ ] **Step 4: Run — passes. Step 5: full suite + commit** (`feat(ax): rename_track`).

---

## Task 5: `checkpoint` — DEFERRED (superseded by Task 1's finding)

**DO NOT IMPLEMENT.** Task 1's real-Logic probe (see `Fixtures/ax/checkpoint.txt`) found that
`File ▸ Save`, `Save As…`, `Save A Copy As…`, AND `Project Alternatives` are all **disabled** in
Logic — confirmed after opening the File menu, so it's real, not stale. Both the primary and the
fallback checkpoint mechanisms are unavailable. Per the user's decision (2026-07-13), the safety
model is **undo-based** instead: structural ops are reversible via Logic-native `Edit ▸ Undo`
(proven: created a track, undid it cleanly). The standalone `checkpoint(label)` snapshot tool is
**deferred to a later phase**. Skip this task entirely; `delete_track` (Task 6) uses undo-based
safety, not auto-checkpoint.

<details><summary>Original (deferred) checkpoint task — for reference only, not to be implemented</summary>

Implement the mechanism Task 1 chose (Project Alternatives `New Alternative…`, else `Save A Copy As…`).

- [ ] **Step 1: Test** — pressing the checkpoint menu path opens a sheet; setting the name field + pressing the confirm button succeeds; a fake models the sheet. Assert the tool returns `{checkpoint: <label>}` and that a missing sheet yields a structured error.

```swift
    func testCheckpointCreatesNamedSnapshot() async throws {
        let p = providerWithCheckpointSheet()   // menu path opens an AXSheet with a name field + "Create"
        let d = await daemon(p)
        let r = try await CheckpointTool(daemon: d).invoke(["label": .string("before delete")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["checkpoint"], .string("before delete"))
    }
```

- [ ] **Step 2: Run — fails. Step 3: Implement** (`StructureTools.swift`) — using the Task 1 selectors:

```swift
public struct CheckpointTool: LogicTool {
    public let name = "checkpoint"
    public let description = "Snapshot the project (Project Alternatives, or a saved copy). Use before destructive edits."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["label": .object(["type": .string("string")])]),
        "required": .array([.string("label")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let label = try requireString(args, "label", tool: name)
        try await makeCheckpoint(daemon, label: label)
        return .object(["checkpoint": .string(label)])
    }
}

/// Menu path + sheet fields per Fixtures/ax/checkpoint decision. PRIMARY: Project Alternatives.
func makeCheckpoint(_ daemon: Daemon, label: String) async throws {
    try await daemon.menu.pressMenuPath(["File", "Project Alternatives", "New Alternative…"])
    try? await Task.sleep(for: .milliseconds(120))
    guard let sheet = daemon.menu.frontSheet() else {
        throw ToolFailure(error: "checkpoint sheet did not appear", layer: "ax",
                          expected: "a New Alternative name sheet", observed: "no sheet")
    }
    try daemon.menu.setField(in: sheet, title: "", to: label)     // exact field title from fixture
    try daemon.menu.pressButton(in: sheet, title: "OK")           // exact button title from fixture
}
```
(If Task 1 chose `Save A Copy As…`, implement THAT path here instead — same shape, different menu path/field/button titles from the fixture. The tool contract is unchanged.)

- [ ] **Step 4: Run — passes. Step 5: full suite + commit** (`feat(ax): checkpoint via <chosen mechanism>`).

</details>

---

## Task 6: `delete_track` (undo-based safety — NO auto-checkpoint)

**Files:** Modify `StructureTools.swift`, `StructureToolTests.swift`.

**Safety change from the spec:** checkpoint is unavailable (Task 1 finding), so `delete_track` does
NOT auto-checkpoint. It performs the delete and verifies by re-read; reversibility is provided by
Logic-native `Edit ▸ Undo`, which `AXMenuDriver` can drive. Expose a small structural-undo so the
delete is agent-reversible.

- [ ] **Step 1: Tests** — (a) delete selects the target then presses `Track ▸ Delete Track` and the strip is gone on re-read; (b) delete of an unknown track throws `layer:"ax"` (via `find`); (c) a small `UndoStructuralTool` presses `Edit ▸ Undo` and (modeled in the fake) restores a just-deleted strip.

```swift
    func testDeleteTrackRemovesStrip() async throws {
        // fake: press "Delete Track" removes the selected strip from the mixer area
        let d = await daemon(providerDeletable("scratch"))
        _ = try await d.axMixer.syncTracks()
        let r = try await DeleteTrackTool(daemon: d).invoke(["name": .string("scratch")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["deleted"], .string("scratch"))
        XCTAssertFalse((try await currentTrackNames(d)).contains("scratch"))
    }
    func testUndoStructuralRestores() async throws {
        // fake: press "Undo" re-adds the last removed strip
        let d = await daemon(providerDeletableWithUndo("scratch"))
        _ = try await d.axMixer.syncTracks()
        _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("scratch")])
        _ = try await UndoStructuralTool(daemon: d).invoke([:])
        XCTAssertTrue((try await currentTrackNames(d)).contains("scratch"))
    }
```

- [ ] **Step 2: Run — fails. Step 3: Implement `DeleteTrackTool` + `UndoStructuralTool` (undo-based safety):**

```swift
public struct DeleteTrackTool: LogicTool {
    public let name = "delete_track"
    public let description = "Delete a track. Reversible via Logic-native undo (call undo_structural to restore). Verified by re-reading the mixer."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")]),
    ])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let name = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(name)             // throws layer:"ax" if unknown
        let resolved = await daemon.ax.read(strip).name
        try await daemon.menu.pressElement(strip)              // select the target
        try await daemon.menu.pressMenuPath(["Track", "Delete Track"])
        let after = try await currentTrackNames(daemon)
        guard !after.contains(resolved) else {
            throw ToolFailure(error: "delete not confirmed", layer: "ax",
                              expected: "'\(resolved)' gone", observed: "still present")
        }
        return .object(["deleted": .string(resolved), "reversible": .string("call undo_structural")])
    }
}

public struct UndoStructuralTool: LogicTool {
    public let name = "undo_structural"
    public let description = "Undo the last structural edit via Logic's Edit ▸ Undo (e.g. reverse a delete_track/create_track)."
    public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        try await daemon.menu.pressMenuPath(["Edit", "Undo"])
        return .object(["undone": .bool(true)])
    }
}
```
The `providerDeletable*` fakes model the effect: a pressed "Delete Track" removes the selected
strip from the mixer `AXLayoutArea`; a pressed "Undo" re-appends it. Use `FakeAXNode.onPress` (Task
2) to wire those effects, mirroring how Task 3's fake models "New Audio Track adds a strip".

- [ ] **Step 4: Run — passes. Step 5: register `DeleteTrackTool`/`UndoStructuralTool`, full suite + commit** (`feat(ax): delete_track (undo-based safety) + undo_structural`).

---

## Task 7: `set_output` (routing popup)

**Files:** Modify `StructureTools.swift`, `StructureToolTests.swift`. Uses `popup_output.txt` (Task 1).

- [ ] **Step 1: Test** — a fake strip whose output button opens a popup with items ("Bus 1"…"Stereo Out"); `set_output(track,"Bus 3")` selects it and re-read shows output "Bus 3". Model the popup + the press updating the strip's output description.
- [ ] **Step 2: Run — fails. Step 3: Implement** `SetOutputTool`:

```swift
public struct SetOutputTool: LogicTool {
    public let name = "set_output"
    public let description = "Set a track's output destination (a bus or output). Verified by re-reading the strip's output slot."
    public let inputSchema = trackArgSchema(["dest": .object(["type": .string("string")])], required: ["dest"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let track = try requireString(args, "track", tool: name)
        let dest = try requireString(args, "dest", tool: name)
        let strip = try await daemon.ax.find(track)
        // The output button has a dynamic description (current dest); AXBridge finds it by exclusion.
        guard let outBtn = await daemon.ax.outputButtonHandle(strip) else {  // expose the private finder
            throw ToolFailure(error: "no output slot on '\(track)'", layer: "ax",
                              expected: "the output-routing button", observed: "none")
        }
        try await daemon.menu.selectPopupItem(from: outBtn, path: [dest])
        let now = await daemon.ax.read(strip).output
        guard now?.caseInsensitiveCompare(dest) == .orderedSame else {
            throw ToolFailure(error: "output change not confirmed", layer: "ax",
                              expected: dest, observed: now ?? "unreadable")
        }
        return .object(["track": .string(track), "output": .string(now ?? dest)])
    }
}
```
Expose the output-button finder on `AXBridge` (it's currently `private func outputButton`): add `public func outputButtonHandle(_ strip: AXHandle) -> AXHandle? { outputButton(strip) }`.

- [ ] **Step 4: Run — passes. Step 5: full suite + commit** (`feat(ax): set_output via routing popup`).

---

## Task 8: `insert_plugin`

**Files:** Create `PluginInsertTool.swift`, `PluginInsertToolTests.swift`. Uses `popup_plugin.txt` (Task 1) — implement whichever path (strip popup vs `Mix ▸ Search and Add Plug-in…`) Task 1 found reliably title-addressable.

- [ ] **Step 1: Test** — `insert_plugin(track, slot, name)` adds a plugin group; re-read via `AXBridge.pluginGroups` shows it. Model the fake so selecting the plugin appends a group to the strip.
- [ ] **Step 2: Run — fails. Step 3: Implement** `InsertPluginTool` — resolve the strip, drive the plugin popup/search per the fixture, then verify `pluginGroups(strip)` contains a group matching `name`:

```swift
public struct InsertPluginTool: LogicTool {
    public let name = "insert_plugin"
    public let description = "Insert an audio plugin on a track's insert slot by name. Verified by re-reading the strip's plugin slots."
    public let inputSchema = trackArgSchema([
        "slot": .object(["type": .string("integer")]),
        "name": .object(["type": .string("string")]),
    ], required: ["name"])
    let daemon: Daemon
    public func invoke(_ args: [String: Value]) async throws -> Value {
        let track = try requireString(args, "track", tool: name)
        let plugin = try requireString(args, "name", tool: name)
        let strip = try await daemon.ax.find(track)
        // Path + selectors from Fixtures/ax/popup_plugin.txt. Example (strip popup):
        guard let slot = await daemon.ax.control(strip, description: "audio plug-in") else {
            throw ToolFailure(error: "no insert slot on '\(track)'", layer: "ax",
                              expected: "the audio plug-in slot", observed: "none")
        }
        try await daemon.menu.selectPopupItem(from: slot, path: pluginMenuPath(for: plugin))  // e.g. ["Audio Units", category, plugin] — fixture decides
        let groups = await daemon.ax.pluginGroups(strip).map(\.name)
        guard groups.contains(where: { $0.caseInsensitiveCompare(plugin) == .orderedSame }) else {
            throw ToolFailure(error: "plugin insert not confirmed", layer: "ax",
                              expected: "'\(plugin)' in the strip's plugin slots",
                              observed: "slots: \(groups.joined(separator: ", "))")
        }
        return .object(["track": .string(track), "plugin": .string(plugin)])
    }
}
```
`pluginMenuPath(for:)` returns the title path from `popup_plugin.txt` (Logic groups stock plugins by category; the fixture gives the exact path, or the search-dialog path if that route was chosen). If the plugin name can't be located, the popup is dismissed and a structured error returned.

- [ ] **Step 4: Run — passes. Step 5: full suite + commit** (`feat(ax): insert_plugin via <chosen path>`).

---

## Task 9: Register all + real-Logic structural smoke (net-zero)

**Files:** Modify `Sources/logic-mcp/Smoke.swift` (add a `--structure` pass) or add a `smoke-structure` mode; modify `docs/integration-smoke.md`; update `CLAUDE.md`/`HANDOFF.md`.

- [ ] **Step 1: Confirm all structure tools are registered** in `Daemon.registerAllTools`.

- [ ] **Step 2: Add a net-zero structural smoke** to `Smoke.swift` (a `structure` subcommand arg) that, against real Logic backgrounded:
  1. `create_track(kind:"audio", name:"__smoke_tmp")` — confirm it appears.
  2. `rename_track("__smoke_tmp", "__smoke_ren")` — confirm.
  3. `set_output("__smoke_ren", <a bus>)` — confirm.
  4. `insert_plugin("__smoke_ren", name:<stock plugin, e.g. "Channel EQ">)` — confirm.
  5. `select_track("vox")` — confirm.
  6. `delete_track("__smoke_ren")` — confirm the strip is gone (RESTORES net-zero; create+delete cancels out).
  7. `undo_structural()` sanity — confirm `Edit ▸ Undo` is drivable (then redo/clean so the project ends net-zero).
  8. Focus check: Logic never frontmost.
  Print PASS/observed per step. No checkpoint step (deferred — Task 1 finding).

- [ ] **Step 3: (CONTROLLER) Run the structural smoke against real Logic**, record results in `docs/integration-smoke.md`'s log (dated), and note any bug the fake couldn't catch (Phase 2's smoke found three — expect structural-op timing/async surprises).

- [ ] **Step 4: Update docs** — `CLAUDE.md` status (Phase 3 done / pending), `HANDOFF.md` (structural ops on AX; any known limitations from the smoke), the smoke log.

- [ ] **Step 5: Commit** (`docs`/`feat`: Phase 3 structural ops verified on real Logic).

---

## Self-review notes (author)

- **Spec coverage:** `AXMenuDriver` (T2), `create_track`/`select_track` (T3), `rename_track` (T4), `checkpoint` (T5), `delete_track`+auto-checkpoint (T6), `set_output` (T7), `insert_plugin` (T8), verification-by-re-read (every tool via `AXMixer`/`AXBridge`), safety spine (T5/T6), net-zero smoke (T9), `axdump menu` + fixtures + checkpoint decision (T1). Non-goals (region ops, VisionVerifier, CGEvent set) untasked — correct.
- **Fixture/probe-dependency** (Phase 2 pattern): T1 captures real menu/dialog/popup titles and the checkpoint mechanism; T4/T5/T7/T8 use those exact titles. Each has a concrete default in the plan text and a fixture-confirmed correction path — no task is a blocked placeholder, but T4 (rename settability), T5 (checkpoint mechanism), and T8 (plugin path) each carry an explicit "implement whichever Task 1 found" branch.
- **Type consistency:** `AXMenuDriver` methods, the two new `AXProvider` methods, the `AXAction` cases, `AXBridge.setValueString`/`outputButtonHandle` passthroughs, and `currentTrackNames`/`renameTrackAX`/`makeCheckpoint` shared helpers are used identically across tasks. `AXMixer.syncTracks()`'s exact return type must be confirmed in T3 Step 3 (flagged inline).
- **Known soft spots the implementer resolves from T1 fixtures (flagged inline):** exact menu-item titles (incl. trailing `…`), whether the strip name field is AXValue-settable (rename path), the checkpoint mechanism + sheet field/button titles, the output popup item titles, and the plugin-insert path + title path.
```
