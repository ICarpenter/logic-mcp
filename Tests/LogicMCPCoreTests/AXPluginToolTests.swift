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

    /// Regression guard for the real-Logic smoke bug: `axEnterPlugin` used to open a slot's
    /// plugin window only if NO plugin window for the track was already up, so with slot 0's
    /// window left open, `get_plugin_params(slot:1)` silently reused it and returned slot 0's
    /// params. Models two slots whose windows are both titled by the TRACK name (as real Logic
    /// does) and only materialize on an "open" press; the fix must close slot 0's window before
    /// opening slot 1's, so slot 1's params are the ones returned.
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
        let raw = try XCTUnwrap(bass.numberValue)
        XCTAssertEqual(raw, 2500, accuracy: 1)   // 25 % → raw 2500 (display = raw/100)
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
}
