import XCTest
@testable import LogicMCPCore

final class AXMixerTests: XCTestCase {
    func testSyncTracksPopulatesModelFromAX() async throws {
        func strip(_ name: String, db: String, mute: String, pan: Double) -> FakeAXNode {
            FakeAXNode(role: "AXLayoutItem", description: name, children: [
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: mute),
                FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
                FakeAXNode(role: "AXStaticText", description: "volume fader level", title: db),
                FakeAXNode(role: "AXSlider", description: "pan", value: pan, settable: true),
                // "group" popup, then the routing slot — the real strip's shape, and the
                // structural anchor AXBridge.outputButton uses to identify the slot.
                FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"),
                FakeAXNode(role: "AXButton", description: "Bus 9"),
            ])
        }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            strip("vox", db: "volume fader level, 0.0 dB", mute: "off", pan: 0),
            strip("bass", db: "volume fader level, -6.0 dB", mute: "on", pan: 10),
        ])
        let root = FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])])
        let model = ProjectModel()
        let mixer = AXMixer(bridge: AXBridge(provider: FakeAXProvider(root: root)), model: model)

        let names = try await mixer.syncTracks()
        XCTAssertEqual(names, ["vox", "bass"])
        let snap = await model.snapshot
        XCTAssertNil(snap.staleAt)
        XCTAssertEqual(snap.tracks[1].name, "bass")
        XCTAssertEqual(snap.tracks[1].volumeDB, -6.0)
        XCTAssertEqual(snap.tracks[1].mute, true)
        XCTAssertEqual(snap.tracks[1].pan, 74)     // 10 + 64
    }
}
