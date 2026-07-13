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
