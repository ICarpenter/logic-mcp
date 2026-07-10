import XCTest
import MCP
@testable import LogicMCPCore

final class AXMixToolTests: XCTestCase {
    func daemon(_ provider: FakeAXProvider) async -> Daemon {
        await Daemon(wire: InMemoryWire(), axProvider: provider)
    }
    func oneStrip(mute: String = "off") -> FakeAXProvider {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: mute),
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "solo", stringValue: "off"),
            FakeAXNode(role: "AXStaticText", description: "volume fader level", title: "volume fader level, 0.0 dB"),
            FakeAXNode(role: "AXSlider", description: "pan", value: 0, settable: true, minValue: -64, maxValue: 63),
            FakeAXNode(role: "AXSlider", description: "volume fader", value: 173, settable: true, minValue: 0, maxValue: 233),
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication",
                              children: [FakeAXNode(role: "AXWindow", children: [area])]))
        p.nudgeMode = true   // model real Logic: AXSetValue nudges ±1 toward target
        return p
    }

    func testMuteOnPressesAndVerifies() async throws {
        let d = await daemon(oneStrip(mute: "off"))
        _ = try await d.axMixer.syncTracks()
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
        let snap = await d.model.snapshot
        XCTAssertEqual(snap.tracks[0].mute, true)
    }

    func testMuteIdempotentWhenAlreadyOn() async throws {
        let d = await daemon(oneStrip(mute: "on"))
        _ = try await d.axMixer.syncTracks()
        // Already on: pressing would turn it OFF, so an idempotent impl must NOT press.
        let result = try await SetMuteTool(daemon: d).invoke(["track": .string("vox"), "on": .bool(true)])
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["mute"], .bool(true))
    }
}
