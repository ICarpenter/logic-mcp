import XCTest
@testable import LogicMCPCore

/// Task 1's sanity tests for the fake AX tree/provider, relocated here when
/// `AXBridgeTests.swift` was replaced (Task 3, Step 5) with real `AXBridge` tests.
/// `testSetNumberUpdatesSettableSlider` asserts absolute-set behavior and relies on
/// `FakeAXProvider.nudgeMode` defaulting to `false` (Task 3, Step 7b) — must stay green.
final class FakeAXTreeSanityTests: XCTestCase {
    /// A minimal mixer: one window holding an AXLayoutArea "Mixer" with one strip "vox".
    func makeMixer() -> FakeAXProvider {
        let volTitle = FakeAXNode(role: "AXStaticText", title: "volume fader level, 0.0 dB")
        let vol = FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true)
        let mute = FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off")
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox",
                               children: [mute, vol, volTitle])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
    }

    func testProviderReadsRoleAndDescription() throws {
        let p = makeMixer()
        let window = p.windows().first!
        let area = p.children(of: window).first!
        XCTAssertEqual(p.string(.description, of: area), "Mixer")
        let strip = p.children(of: area).first!
        XCTAssertEqual(p.string(.role, of: strip), "AXLayoutItem")
        XCTAssertEqual(p.string(.description, of: strip), "vox")
    }

    func testPerformPressFlipsSwitchValue() throws {
        let p = makeMixer()
        let strip = p.children(of: p.children(of: p.windows().first!).first!).first!
        let mute = p.children(of: strip).first { p.string(.description, of: $0) == "mute" }!
        XCTAssertEqual(p.string(.value, of: mute), "off")
        try p.perform(.press, on: mute)
        XCTAssertEqual(p.string(.value, of: mute), "on")
    }

    func testSetNumberUpdatesSettableSlider() throws {
        let p = makeMixer()
        let strip = p.children(of: p.children(of: p.windows().first!).first!).first!
        let vol = p.children(of: strip).first { p.string(.description, of: $0) == "volume fader" }!
        XCTAssertTrue(p.isSettable(vol))
        try p.setNumber(200, of: vol)
        XCTAssertEqual(p.number(of: vol), 200)
    }
}
