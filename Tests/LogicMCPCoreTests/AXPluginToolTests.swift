import XCTest
import MCP
@testable import LogicMCPCore

final class AXPluginToolTests: XCTestCase {
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

    /// Regression guard for the real-Logic smoke bug: the AX plugin-entry path used to open a
    /// slot's plugin window only if NO plugin window for the track was already up, so with slot
    /// 0's window left open, `get_plugin_params(slot:1)` silently reused it and returned slot 0's
    /// params. Models two slots whose windows are both titled by the TRACK name (as real Logic
    /// does) and only materialize on an "open" press; `axEnterPluginControls` must close slot 0's
    /// window before opening slot 1's, so slot 1's params are the ones returned.
    func testGetPluginParamsSlot1DoesNotReturnSlot0() async throws {
        func controlsWindow(title: String, label: String) -> FakeAXNode {
            let control = FakeAXNode(role: "AXSlider", value: 240, settable: true, minValue: 0, maxValue: 480)
            let group = FakeAXNode(role: "AXGroup", stringValue: "0.00")
            let cell = FakeAXNode(role: "AXCell", children: [
                FakeAXNode(role: "AXStaticText", stringValue: label), group, control])
            let table = FakeAXNode(role: "AXTable",
                children: [FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])])
            let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls")
            let close = FakeAXNode(role: "AXButton", description: "close")
            let window = FakeAXNode(role: "AXWindow", title: title, children: [
                close, viewBtn, FakeAXNode(role: "AXScrollArea", children: [table])])
            close.closesWindow = window
            return window
        }
        let eqWindow = controlsWindow(title: "vox", label: "Gain:")
        let compWindow = controlsWindow(title: "vox", label: "Threshold:")

        let eqOpen = FakeAXNode(role: "AXButton", description: "open")
        eqOpen.opensWindow = eqWindow
        let eqGroup = FakeAXNode(role: "AXGroup", description: "Channel EQ", children: [eqOpen])

        let compOpen = FakeAXNode(role: "AXButton", description: "open")
        compOpen.opensWindow = compWindow
        let compGroup = FakeAXNode(role: "AXGroup", description: "Compressor", children: [compOpen])

        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            eqGroup, compGroup,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        // No plugin window pre-present — both must be opened on demand, mirroring real Logic.
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
            children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area])]))
        p.nudgeMode = true
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()

        let r0 = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
        guard case .object(let o0) = r0, case .array(let params0)? = o0["params"], case .object(let p0)? = params0.first
        else { return XCTFail() }
        XCTAssertEqual(p0["name"], .string("Gain"))

        // Slot 0's window is still "open" in Logic's UI at this point — the bug reused it here.
        let r1 = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(1)])
        guard case .object(let o1) = r1, case .array(let params1)? = o1["params"], case .object(let p1)? = params1.first
        else { return XCTFail() }
        XCTAssertEqual(p1["name"], .string("Threshold"), "slot 1 must return its OWN params, not slot 0's stale Gain")
    }

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
        p.nudgeMode = false   // Task 0 default: AXSetValue is absolute on Controls-view sliders
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
        let raw = try XCTUnwrap(bass.numberValue)
        XCTAssertEqual(raw, 2500, accuracy: 1)   // 25 % → raw 2500 (display = raw/100)
    }

    /// Regression for the whole-branch review's index-space mismatch: `get_plugin_params` numbers
    /// controls over the FULL list (sliders + toggles + popups in tree order), but a sliders-only
    /// filtered resolution would put a DIFFERENT control at a given integer index than the one just
    /// advertised — silently targeting the wrong slider while still reporting `verified:true`.
    /// A Controls window whose rows are [slider "A", toggle "B", slider "C"]: `get_plugin_params`
    /// would list "C" at index 2, but `sliders` (name-filtered) only has 2 entries ([A, C]) — index
    /// 2 there is out of range / a different control. `set_plugin_param(param:"2")` must resolve
    /// against the FULL list and target slider "C".
    func makeMixedKindProvider() -> (FakeAXProvider, a: FakeAXNode, c: FakeAXNode) {
        let aGroup = FakeAXNode(role: "AXGroup", stringValue: "0.00")
        let a = FakeAXNode(role: "AXSlider", value: 0, settable: true, minValue: 0, maxValue: 10)
        let aCell = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "A:"), aGroup, a])
        let b = FakeAXNode(role: "AXCheckBox", stringValue: "0", settable: true)
        let bCell = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "B:"), b])
        let cGroup = FakeAXNode(role: "AXGroup", stringValue: "0.00")
        let c = FakeAXNode(role: "AXSlider", value: 0, settable: true, minValue: 0, maxValue: 10)
        let cCell = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "C:"), cGroup, c])
        let table = FakeAXNode(role: "AXTable", children: [
            FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [aCell]),
            FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [bCell]),
            FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cCell]),
        ])
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
        p.nudgeMode = false   // Task 0 default: AXSetValue is absolute on Controls-view sliders
        return (p, a: a, c: c)
    }

    func testSetPluginParamIntegerIndexUsesFullControlSpace() async throws {
        let (p, _, c) = makeMixedKindProvider()
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        let r = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("2"), "value": .double(0.5)])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["param"], .string("C"), "index '2' in the FULL control list is slider C, not sliders[2]")
        XCTAssertEqual(o["verified"], .bool(true))
        let raw = try XCTUnwrap(c.numberValue)
        XCTAssertEqual(raw, 5, accuracy: 1)   // 0.5 normalized over 0…10 → midpoint 5
    }

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

    /// Regression for `convergeAdaptive`/`convergeByBisection`'s settle-poll guard (`settledValue`):
    /// real Logic updates a plugin slider's raw AX value ASYNCHRONOUSLY after `AXSetValue`
    /// (ax-findings.md) — an immediate re-read can return the stale pre-write value,
    /// indistinguishable from a genuine stuck boundary. `setValueLatency` on the target slider
    /// models exactly that: it holds the new raw value back for one subsequent `number(of:)` read.
    /// Range kept tiny (0…6) so the test only pays the guard's 30ms poll a handful of times rather
    /// than thousands.
    /// SUCCESS CRITERION (verified manually per the brief): this test goes RED if the `settledValue`
    /// poll loop is deleted from `convergeByBisection`'s stuck-check (an unguarded single read sees
    /// the stale raw on the very first nudge, misreads it as "stuck", and bails with the display
    /// still at 1% instead of the 3% target — `verified` becomes false).
    func testSetPluginParamUnitTargetSettlesAsyncSliderReadback() async throws {
        let group = FakeAXNode(role: "AXGroup", stringValue: "0 %")
        let bass  = FakeAXNode(role: "AXSlider", value: 0, settable: true, minValue: 0, maxValue: 6)
        bass.setValueLatency = 1
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
        p.nudgeMode = false   // Task 0 default: AXSetValue is absolute on Controls-view sliders
        // Display tracks the raw 1:1 (unlike makeConvergingProvider's /100) so a handful of
        // nudges is enough to reach the target — keeps the test's real 30ms settle-polls brief.
        p.onSetNumber = { node, raw in
            if node === bass { group.stringValue = "\(Int(raw)) %" }
        }

        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        let r = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Bass"), "value": .string("3 %")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["verified"], .bool(true))
        let raw = try XCTUnwrap(bass.numberValue)
        XCTAssertEqual(raw, 3, accuracy: 1)
    }

    /// The normalized-0–1 branch (`nudgeToRaw`), distinct from the unit-string `convergeAdaptive`
    /// path above: a plain JSON number (`.double`, not a string) maps onto the slider's raw range.
    func testSetPluginParamNormalizedValueConvergesToRawMidpoint() async throws {
        let (p, bass) = makeConvergingProvider()   // minMax 0…10000
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        let r = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Bass"), "value": .double(0.5)])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["verified"], .bool(true))
        let raw = try XCTUnwrap(bass.numberValue)
        XCTAssertEqual(raw, 5000, accuracy: 1)   // 0.5 normalized over 0…10000 → midpoint 5000
    }

    /// An opaque plugin (no Controls-view AXTable) must throw a clear, spec-matching error rather
    /// than falling through to the generic "no parameter" message meant for a real miss.
    func testSetPluginParamOpaquePluginThrowsAddressableParamsError() async throws {
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
        do {
            _ = try await SetPluginParamTool(daemon: d).invoke([
                "track": .string("vox"), "slot": .int(0), "param": .string("Gain"), "value": .double(0.5)])
            XCTFail("expected an opaque-plugin ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.error, "plugin exposes no addressable parameters")
            XCTAssertEqual(f.observed, "opaque plugin")
        }
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

    /// Contract from the brief: `controlTable(in:)` returns [] when the plugin window has NO
    /// AXTable descendant (an opaque plugin, e.g. a UAD Editor view whose group is AXUnknown, or
    /// a window still in Editor view). Never fabricate rows for an untabled window.
    func testControlTableOpaquePluginReturnsEmpty() async throws {
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXGroup", subrole: "AXUnknown"),
        ])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let handle = try await firstWindowHandle(bridge, title: "vox")
        let controls = await bridge.controlTable(in: handle)
        XCTAssertTrue(controls.isEmpty, "an opaque plugin (no AXTable) must yield no rows")
    }

    /// Proves the real UAD Controls dump parses (third-party coverage).
    func testControlTableParsesUADFixture() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("plugin_controls_uad_bx20"))
        let handle = try await firstWindowHandle(bridge, title: "guitar")
        let controls = await bridge.controlTable(in: handle)
        XCTAssertTrue(controls.contains { $0.name == "Dry/Wet" }, "UAD params must be named")
        XCTAssertTrue(controls.contains { $0.name == "Bass" && $0.kind == .slider })
    }

    /// Helper: resolve a window handle by title from a bare AXBridge.
    private func firstWindowHandle(_ bridge: AXBridge, title: String) async throws -> AXHandle {
        let ws = await bridge.windowsForTest()
        for w in ws where await bridge.titleForTest(w) == title { return w }
        throw XCTSkip("no window '\(title)'")
    }

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

    /// Regression for the live opaque:true race: the Controls AXTable populates async after the view
    /// switch. `settledControlTable` must poll past the empty reads; a single `controlTable` sees [].
    func testSettledControlTablePollsPastEmptyReads() async throws {
        let slider = FakeAXNode(role: "AXSlider", value: 240, settable: true, minValue: 0, maxValue: 480)
        let cell = FakeAXNode(role: "AXCell", children: [
            FakeAXNode(role: "AXStaticText", stringValue: "Gain:"),
            FakeAXNode(role: "AXGroup", stringValue: "0.0 dB"), slider])
        let row = FakeAXNode(role: "AXRow", subrole: "AXTableRow", children: [cell])
        let table = FakeAXNode(role: "AXTable")                 // starts EMPTY
        table.scheduleChildAppend(row, afterReads: 2)           // row appears only after 2 children reads
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Controls"),
            FakeAXNode(role: "AXScrollArea", children: [table])])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let handle = try await firstWindowHandle(bridge, title: "vox")
        let firstRead = await bridge.controlTable(in: handle)
        XCTAssertTrue(firstRead.isEmpty, "first single read sees the empty table")
        let settled = await bridge.settledControlTable(in: handle)
        XCTAssertEqual(settled.map(\.name), ["Gain"], "settledControlTable polls until the row populates")
    }

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
}
