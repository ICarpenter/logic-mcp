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

    private func popupTree(desc: String, initial: String, choices: [String]) -> (FakeAXProvider, FakeAXNode) {
        let popup = FakeAXNode(role: "AXPopUpButton", description: desc, stringValue: initial)
        let items = choices.map { c -> FakeAXNode in
            let item = FakeAXNode(role: "AXMenuItem", title: c)
            item.onPress = { [weak popup] in popup?.stringValue = c }   // Logic commits the popup value
            return item
        }
        popup.children = [FakeAXNode(role: "AXMenu", children: items)]
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [popup])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return (FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange])), popup)
    }

    func testSetTimeSignature() async {
        let (provider, _) = popupTree(desc: "Time Signature", initial: "4/4", choices: ["3/4", "4/4", "6/8"])
        let (_, reg) = await makeDaemon(provider)
        let (json, isErr) = await callJSON(reg, "set_time_signature", ["signature": .string("6/8")])
        XCTAssertFalse(isErr)
        // JSONEncoder (unconfigured, used throughout ToolRegistry) escapes "/" as "\/" — accept either form.
        XCTAssertTrue(json.contains("\"display\":\"6/8\"") || json.contains("\"display\":\"6\\/8\""), json)
        XCTAssertTrue(json.contains("\"verified\":true"), json)
    }

    func testSetKeySignatureUnknownChoiceErrorsWithList() async {
        let (provider, _) = popupTree(desc: "Key Signature", initial: "C Major", choices: ["C Major", "A Minor"])
        let (_, reg) = await makeDaemon(provider)
        let (json, isErr) = await callJSON(reg, "set_key_signature", ["key": .string("Z Lydian")])
        XCTAssertTrue(isErr)
        XCTAssertTrue(json.contains("A Minor"), json)   // error lists the live choices
    }

    private func playheadTree(bar: Double = 1, beat: Double = 1) -> FakeAXProvider {
        let barS = FakeAXNode(role: "AXSlider", description: "bar", value: bar, settable: true, minValue: 1, maxValue: 999)
        let beatS = FakeAXNode(role: "AXSlider", description: "beat", value: beat, settable: true, minValue: 1, maxValue: 16)
        let pos = FakeAXNode(role: "AXGroup", description: "Playhead Position", children: [barS, beatS])
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [pos])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetPlayheadBarAndBeat() async {
        let (_, reg) = await makeDaemon(playheadTree())
        let (json, isErr) = await callJSON(reg, "set_playhead", ["bar": .int(9), "beat": .int(3)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"bar\":9"), json)
        XCTAssertTrue(json.contains("\"beat\":3"), json)
    }

    func testSetPlayheadBarOnlyDefaultsBeat() async {
        let (_, reg) = await makeDaemon(playheadTree(bar: 5, beat: 2))
        let (json, isErr) = await callJSON(reg, "set_playhead", ["bar": .int(12)])
        XCTAssertFalse(isErr)
        XCTAssertTrue(json.contains("\"bar\":12"), json)
        XCTAssertTrue(json.contains("\"beat\":1"), json)
    }

    /// Arrange headers where pressing a Has-Focus radio behaves like a radio group.
    private func headersTree(_ names: [String], focusedIndex: Int) -> FakeAXProvider {
        var radios: [FakeAXNode] = []
        var items: [FakeAXNode] = []
        for (i, n) in names.enumerated() {
            let radio = FakeAXNode(role: "AXRadioButton", description: "Has Focus",
                                   stringValue: i == focusedIndex ? "1" : "0")
            radios.append(radio)
            let nameField = FakeAXNode(role: "AXTextField", description: n, value: 0)
            items.append(FakeAXNode(role: "AXLayoutItem", description: "Track \(i + 1) “\(n)”",
                                    children: [radio, nameField]))
        }
        for r in radios { r.onPress = { for x in radios { x.stringValue = (x === r) ? "1" : "0" } } }
        let hdr = FakeAXNode(role: "AXGroup", description: "Tracks header", children: items)
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [hdr])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    /// select_track is DISABLED (Task 0 live probe: the arrange header's Has Focus control is a
    /// read-only status indicator; AXPress on it is a no-op) — it must always return a structured
    /// error and never press anything.
    func testSelectTrackIsDisabled() async {
        let (_, reg) = await makeDaemon(headersTree(["vox", "Rugrats", "bass"], focusedIndex: 0))
        let (json, isErr) = await callJSON(reg, "select_track", ["name": .string("Rugrats")])
        XCTAssertTrue(isErr, json)
        XCTAssertTrue(json.contains("not available"), json)
    }

    private func cycleTree(enabled: Bool) -> FakeAXProvider {
        // Cycle is a press-only checkbox (settable=false); the fake flips "1"/"0" on press.
        let cycle = FakeAXNode(role: "AXCheckBox", description: "Cycle", stringValue: enabled ? "1" : "0")
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cycle])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange]))
    }

    func testSetCycleEnable() async {
        let (_, reg) = await makeDaemon(cycleTree(enabled: false))
        let (json, isErr) = await callJSON(reg, "set_cycle", ["enabled": .bool(true)])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"enabled\":true"), json)
    }

    func testSetCycleAlreadyInStateIsNoOp() async {
        let (_, reg) = await makeDaemon(cycleTree(enabled: true))
        let (json, isErr) = await callJSON(reg, "set_cycle", ["enabled": .bool(true)])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"enabled\":true"), json)
    }

    func testGetArrangeState() async {
        // Reuse a full tree: tempo 128, time 6/8, key A Minor, playhead bar 3 beat 2, cycle on.
        let tempo = FakeAXNode(role: "AXSlider", description: "Tempo", value: 128, settable: true, minValue: 5, maxValue: 990)
        let bar = FakeAXNode(role: "AXSlider", description: "bar", value: 3, settable: true, minValue: 1, maxValue: 999)
        let beat = FakeAXNode(role: "AXSlider", description: "beat", value: 2, settable: true, minValue: 1, maxValue: 16)
        let pos = FakeAXNode(role: "AXGroup", description: "Playhead Position", children: [bar, beat])
        let time = FakeAXNode(role: "AXPopUpButton", description: "Time Signature", stringValue: "6/8")
        let key = FakeAXNode(role: "AXPopUpButton", description: "Key Signature", stringValue: "A Minor")
        let cycle = FakeAXNode(role: "AXCheckBox", description: "Cycle", stringValue: "1")
        let cbInner = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [tempo, pos, time, key, cycle])
        let cbOuter = FakeAXNode(role: "AXGroup", description: "Control Bar", children: [cbInner])
        // A Tracks header with one focused track — get_arrange_state reads selection (it only SETS
        // selection that's unavailable via AX), so this is the same headersTree shape as above.
        let focusRadio = FakeAXNode(role: "AXRadioButton", description: "Has Focus", stringValue: "1")
        let nameField = FakeAXNode(role: "AXTextField", description: "vox", value: 0)
        let headerItem = FakeAXNode(role: "AXLayoutItem", description: "Track 1 “vox”",
                                    children: [focusRadio, nameField])
        let header = FakeAXNode(role: "AXGroup", description: "Tracks header", children: [headerItem])
        let arrange = FakeAXNode(role: "AXWindow", title: "p - Tracks", children: [cbOuter, header])
        let (_, reg) = await makeDaemon(FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [arrange])))
        let (json, isErr) = await callJSON(reg, "get_arrange_state", [:])
        XCTAssertFalse(isErr, json)
        XCTAssertTrue(json.contains("\"tempo\":128"), json)
        // JSONEncoder (unconfigured, used throughout ToolRegistry) escapes "/" as "\/" — accept either form.
        XCTAssertTrue(json.contains("\"timeSignature\":\"6/8\"") || json.contains("\"timeSignature\":\"6\\/8\""), json)
        XCTAssertTrue(json.contains("\"keySignature\":\"A Minor\""), json)
        XCTAssertTrue(json.contains("\"bar\":3"), json)
        XCTAssertTrue(json.contains("\"cycling\":true"), json)
        XCTAssertTrue(json.contains("\"selectedTrack\":\"vox\""), json)
    }
}
