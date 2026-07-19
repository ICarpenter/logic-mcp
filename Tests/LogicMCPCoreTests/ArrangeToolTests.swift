import XCTest
import MCP
@testable import LogicMCPCore

final class ArrangeToolTests: XCTestCase {
    /// A daemon wired to a fake arrange tree. `nudge` models real-Logic ±1 sliders when true.
    func makeDaemon(_ provider: FakeAXProvider, nudge: Bool = false) async -> (Daemon, ToolRegistry) {
        provider.nudgeMode = nudge
        let (end, _) = InMemoryWire.pair()
        let daemon = await Daemon(wire: end, axProvider: provider)
        let reg = ToolRegistry()
        await daemon.registerAllTools(in: reg)
        return (daemon, reg)
    }

    func callJSON(_ reg: ToolRegistry, _ name: String, _ args: [String: Value]) async -> (String, Bool) {
        let r = await reg.call(name: name, arguments: args)
        let t = r.content.compactMap { if case .text(let s, _, _) = $0 { return s } else { return nil } }.joined()
        return (t, r.isError ?? false)
    }

    private func arrangeOnlyTree(tempo: Double = 120) -> FakeAXProvider {
        let t = FakeAXNode(role: "AXSlider", description: "Tempo", value: tempo, settable: true,
                           minValue: 5, maxValue: 990)
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [t])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetTempoAbsolute() async {
        let (_, reg) = await makeDaemon(arrangeOnlyTree(tempo: 120))
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .double(140)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"tempo\":140"), json)
        XCTAssertTrue(json.contains("\"verified\":true"), json)
    }

    func testSetTempoConvergesUnderNudge() async {
        let (_, reg) = await makeDaemon(arrangeOnlyTree(tempo: 120), nudge: true)
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .int(130)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"tempo\":130"), json)
    }

    func testSetTempoNoArrangeWindowErrors() async {
        let empty = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: []))
        let (_, reg) = await makeDaemon(empty)
        let (json, isErr) = await callJSON(reg, "set_tempo", ["bpm": .int(120)])
        XCTAssertTrue(isErr)
        XCTAssertTrue(json.contains("arrange window"), json)
    }
}
