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
        let title = await bridge.stringValue(.title, of: w!)
        XCTAssertEqual(title, "mcp_test.logicx - Tracks")
    }

    func testControlBarGettersResolve() async {
        let bridge = AXBridge(provider: makeTree())
        let tempo = await bridge.controlBarControl(role: "AXSlider", description: "Tempo")
        let tempoValue = await bridge.value(of: tempo!)
        XCTAssertEqual(tempoValue, 120)
        let key = await bridge.controlBarControl(role: "AXPopUpButton", description: "Key Signature")
        let keyValue = await bridge.stringValue(.value, of: key!)
        XCTAssertEqual(keyValue, "C Major")
    }

    func testArrangeHeadersParseNamesAndFocus() async {
        let bridge = AXBridge(provider: makeTree())
        let items = await bridge.arrangeHeaderItems()
        XCTAssertEqual(items.map(\.name), ["vox", "Rugrats"])
        let voxFocus = await bridge.hasFocusRadio(in: items[0].item)
        let voxFocusValue = await bridge.stringValue(.value, of: voxFocus!)
        XCTAssertEqual(voxFocusValue, "1")
    }

    func testParseTrackHeaderName() {
        XCTAssertEqual(AXBridge.parseTrackHeaderName("Track 2 “Rugrats”"), "Rugrats")
        XCTAssertNil(AXBridge.parseTrackHeaderName("Tracks header"))
    }
}
