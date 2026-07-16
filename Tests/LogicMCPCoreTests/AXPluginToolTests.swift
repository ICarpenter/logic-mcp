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
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
            gain, freq,
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

    /// Regression guard for the real-Logic smoke bug: `axEnterPlugin` used to open a slot's
    /// plugin window only if NO plugin window for the track was already up, so with slot 0's
    /// window left open, `get_plugin_params(slot:1)` silently reused it and returned slot 0's
    /// params. Models two slots whose windows are both titled by the TRACK name (as real Logic
    /// does) and only materialize on an "open" press; the fix must close slot 0's window before
    /// opening slot 1's, so slot 1's params are the ones returned.
    func testGetPluginParamsSlot1DoesNotReturnSlot0() async throws {
        let eqGain = FakeAXNode(role: "AXSlider", description: "Gain", title: "0.0 dB",
                                value: 240, settable: true, minValue: 0, maxValue: 480)
        let eqClose = FakeAXNode(role: "AXButton", description: "close")
        let eqWindow = FakeAXNode(role: "AXWindow", title: "vox", children: [
            eqClose, FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"), eqGain,
        ])
        eqClose.closesWindow = eqWindow

        let compThreshold = FakeAXNode(role: "AXSlider", description: "Threshold", title: "-20 dB",
                                       value: 100, settable: true, minValue: 0, maxValue: 200)
        let compClose = FakeAXNode(role: "AXButton", description: "close")
        let compWindow = FakeAXNode(role: "AXWindow", title: "vox", children: [
            compClose, FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"), compThreshold,
        ])
        compClose.closesWindow = compWindow

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
        // No plugin window pre-present — both must be opened on demand, mirroring real Logic
        // (unlike `makeProvider()` below, which pre-opens slot 0's window for Task 10's
        // untested "cold start" branch).
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

    /// `param` can be given as an integer index into the deduped param list. A negative
    /// integer must fall through to the structured "no parameter" error, never trap on a
    /// negative array subscript (regression guard for the brief's transcribed
    /// `Int(paramKey).flatMap { i in i < params.count ? params[i] : nil }`, which has no
    /// lower bound).
    func testSetPluginParamNegativeIndexDoesNotCrash() async throws {
        let d = await Daemon(wire: InMemoryWire(), axProvider: makeProvider())
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await SetPluginParamTool(daemon: d).invoke([
                "track": .string("vox"), "slot": .int(0), "param": .string("-1"), "value": .double(0.5)])
            XCTFail("expected a no-parameter ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("-1"))
        }
    }

    /// A plugin window whose only controls are non-settable (e.g. a read-only meter) must
    /// return the structured "parameters not accessible" error — never fabricate params for
    /// an opaque third-party plugin (ax-findings.md §Plugins).
    func testGetPluginParamsOpaquePluginReturnsStructuredError() async throws {
        let meter = FakeAXNode(role: "AXSlider", description: "Input Level", title: "-inf",
                               value: 0, settable: false)
        let pluginWindow = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
            meter,
        ])
        let opaqueGroup = FakeAXNode(role: "AXGroup", description: "SomeThirdPartyAU", children: [
            FakeAXNode(role: "AXButton", description: "open"),
        ])
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            opaqueGroup,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
            children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer", children: [area]), pluginWindow]))
        p.nudgeMode = true
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
            XCTFail("expected a not-accessible ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("not accessible"))
        }
    }

    /// Real Logic exposes the same param description more than once (e.g. "Gain" on the
    /// master slider AND its AXValueIndicator — see plugin_window.txt). `get_plugin_params`
    /// must dedupe to one entry per name, and `set_plugin_param` must land on the first
    /// settable slider, never the read-only indicator.
    func testDuplicateParamNamesAreDeduped() async throws {
        let gain1 = FakeAXNode(role: "AXSlider", description: "Gain", title: "0.0 dB",
                               value: 240, settable: true, minValue: 0, maxValue: 480)
        let gainIndicator = FakeAXNode(role: "AXValueIndicator", description: "Gain")
        let gain2 = FakeAXNode(role: "AXSlider", description: "Gain", title: "0.0 dB",
                               value: 240, settable: true, minValue: 0, maxValue: 480)
        let pluginWindow = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
            gain1, gainIndicator, gain2,
        ])
        let eqGroup = FakeAXNode(role: "AXGroup", description: "Channel EQ", children: [
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
        let d = await Daemon(wire: InMemoryWire(), axProvider: p)
        _ = try await d.axMixer.syncTracks()

        let listed = try await GetPluginParamsTool(daemon: d).invoke(["track": .string("vox"), "slot": .int(0)])
        guard case .object(let o) = listed, case .array(let params)? = o["params"] else { return XCTFail() }
        XCTAssertEqual(params.count, 1, "the 3 'Gain'-described controls must dedupe to 1")

        _ = try await SetPluginParamTool(daemon: d).invoke([
            "track": .string("vox"), "slot": .int(0), "param": .string("Gain"), "value": .double(0.0)])
        // Only the first settable slider (gain1) may have moved; the second ("gain2") and the
        // non-settable indicator must be untouched.
        XCTAssertNotEqual(gain1.numberValue, 240, "the targeted (first, deduped) slider must have moved")
        XCTAssertEqual(gain2.numberValue, 240, "a later duplicate-named slider must NOT be touched")
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
