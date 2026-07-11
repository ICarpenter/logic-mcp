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
            FakeAXNode(role: "AXButton", description: "close"), meter,
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
            FakeAXNode(role: "AXButton", description: "close"), gain1, gainIndicator, gain2,
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
}
