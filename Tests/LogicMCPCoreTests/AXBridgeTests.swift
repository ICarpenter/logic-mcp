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

    /// The ARRANGE window's Inspector contains a MINI-MIXER with the SAME role+description
    /// ("AXLayoutArea"/"Mixer") as the real Mixer window's full strip list — showing only the
    /// selected track's strip (+ its output), e.g. ["vox", "Aux 1"]. Phase-2 `mixerArea()` took
    /// the FIRST match across `windows()`, which worked only because the real Mixer window
    /// happened to come first — if window order shifted, `stripHandles()` would silently read
    /// the 2-strip mini-mixer instead of the full 20-strip mixer (see Fixtures/ax/rename.txt).
    /// This must resolve to the 20-strip mixer regardless of window order.
    func twoMixerAreasProvider(mixerWindowFirst: Bool) -> FakeAXProvider {
        func stripNode(_ name: String) -> FakeAXNode {
            FakeAXNode(role: "AXLayoutItem", description: name)
        }
        let miniMixer = FakeAXNode(role: "AXLayoutArea", description: "Mixer",
                                   children: [stripNode("vox"), stripNode("Aux 1")])
        let tracksWindow = FakeAXNode(role: "AXWindow", title: "mcp_test.logicx - Tracks",
                                      children: [miniMixer])

        let fullMixer = FakeAXNode(role: "AXLayoutArea", description: "Mixer",
                                   children: (1...20).map { stripNode("Strip \($0)") })
        let mixerWindow = FakeAXNode(role: "AXWindow", title: "mcp_test.logicx - Mixer: Tracks",
                                     children: [fullMixer])

        let windows = mixerWindowFirst ? [mixerWindow, tracksWindow] : [tracksWindow, mixerWindow]
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: windows))
    }

    func testStripHandlesIgnoresInspectorMiniMixer_MixerWindowFirst() async throws {
        let bridge = AXBridge(provider: twoMixerAreasProvider(mixerWindowFirst: true))
        let names = try await bridge.stripHandles().map(\.name)
        XCTAssertEqual(names.count, 20)
        XCTAssertFalse(names.contains("Aux 1"), "must not bind the Inspector mini-mixer")
    }

    func testStripHandlesIgnoresInspectorMiniMixer_TracksWindowFirst() async throws {
        let bridge = AXBridge(provider: twoMixerAreasProvider(mixerWindowFirst: false))
        let names = try await bridge.stripHandles().map(\.name)
        XCTAssertEqual(names.count, 20)
        XCTAssertFalse(names.contains("Aux 1"), "must not bind the Inspector mini-mixer")
    }
}
