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
                FakeAXNode(role: "AXButton", description: "Bus 9"),
            ])
        }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            strip("vox", db: "volume fader level, 0.0 dB", mute: "off", pan: 0),
            strip("bass", db: "volume fader level, -6.0 dB", mute: "on", pan: 10),
        ])
        let root = FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", children: [area])])
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
