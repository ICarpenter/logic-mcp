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
                // The routing slot is the plain AXButton IMMEDIATELY AFTER the "group" popup —
                // that structural anchor is how it's identified (Fixtures/ax/mixer_strip.txt,
                // strip_special.txt), so the fake must carry the anchor like real Logic does.
                FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"),
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

    /// Real Logic (2026-07-15, mcp_test.logicx): strips scrolled OFF-SCREEN come back with a
    /// numeric-GARBAGE `AXLayoutItem` description ("88 1 4") instead of the track name, while
    /// the child `AXTextField description="name"` still carries the true name ("vox"). Observed
    /// live for vox, Aux 1, Stereo Out and Master — `get_track("Stereo Out")` failed with
    /// "no track named 'Stereo Out'" and `refresh_state` listed them under the garbage names.
    /// Strip names must be read from the name FIELD, never the layout-item description.
    func offscreenGarbageNameProvider() -> FakeAXProvider {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "88 1 4", children: [
            FakeAXNode(role: "AXTextField", description: "name", stringValue: "vox"),
            FakeAXNode(role: "AXButton", subrole: "AXSwitch", description: "mute", stringValue: "off"),
            FakeAXNode(role: "AXSlider", description: "pan", value: 0, settable: true),
            FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"),
            FakeAXNode(role: "AXButton", description: "output"),
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        return FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
    }

    func testStripHandlesReadsNameFromNameFieldNotGarbageLayoutDescription() async throws {
        let bridge = AXBridge(provider: offscreenGarbageNameProvider())
        let names = try await bridge.stripHandles().map(\.name)
        XCTAssertEqual(names, ["vox"])
    }

    func testReadUsesNameFieldForOffscreenGarbageStrip() async throws {
        let bridge = AXBridge(provider: offscreenGarbageNameProvider())
        let handle = try await bridge.stripHandles()[0].handle
        let c = await bridge.read(handle)
        XCTAssertEqual(c.name, "vox")
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

    // MARK: - BUG 1: the output slot is identified POSITIVELY (Fixtures/ax/strip_special.txt)
    //
    // The old `outputButton()` found the routing slot by EXCLUSION — the first AXButton whose
    // description isn't a known fixed label. On strips that have NO routing slot at all it
    // therefore matched an unrelated mixer-panel button: live, `Stereo Out` reported its output as
    // "bounce" and `Master` as "dim" (both AXSwitches). The slot must instead be found
    // structurally: the IMMEDIATE NEXT SIBLING of the `AXPopUpButton description="group"`, accepted
    // only if it's a plain AXButton (no subrole, no value) whose description isn't a fixed label.
    // No slot ⇒ nil. A wrong answer is worse than no answer. (NOT a `Bus \d+` regex — buses are
    // renamable.) These tests parse the REAL captured tree.

    func testOutputSlotReadFromRealCapture() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("strip_special"))
        let liverpool = await bridge.read(try await bridge.find("Liverpool"))
        XCTAssertEqual(liverpool.output, "Bus 21", "normal audio track routes to a renamed/regular bus")
        let inst = await bridge.read(try await bridge.find("Inst 2"))
        XCTAssertEqual(inst.output, "Bus 9", "software instrument")
        let aux = await bridge.read(try await bridge.find("Aux 1"))
        XCTAssertEqual(aux.output, "Stereo Output", "aux")
    }

    func testStereoOutHasNoOutputSlot() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("strip_special"))
        let strip = try await bridge.find("Stereo Out")
        let button = await bridge.outputButtonHandle(strip)
        let output = await bridge.read(strip).output
        XCTAssertNil(button, "Stereo Out has NO routing button — the next sibling after 'group' is a plugin slot")
        XCTAssertNil(output, "refresh_state must report no output, not the 'bounce' switch")
    }

    func testMasterHasNoOutputSlot() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("strip_special"))
        let strip = try await bridge.find("Master")
        let button = await bridge.outputButtonHandle(strip)
        let output = await bridge.read(strip).output
        XCTAssertNil(button, "Master has NO routing button — the next sibling after 'group' is the 'dim' AXSwitch")
        XCTAssertNil(output, "refresh_state must report no output, not the 'dim' switch")
    }

    /// A bus can be RENAMED in Logic, so the routing slot's description is arbitrary text — the
    /// structural anchor (next sibling after "group") must still find it, and a name-shape regex
    /// (`Bus \d+`) must never be what identifies it.
    func testRenamedBusIsStillFoundAsTheOutputSlot() async throws {
        let p = AXFixture.provider("strip_special")
        AXFixture.find([p.rootNode], description: "Bus 21")?.description = "Drum Buss"
        let bridge = AXBridge(provider: p)
        let liverpool = await bridge.read(try await bridge.find("Liverpool"))
        XCTAssertEqual(liverpool.output, "Drum Buss")
    }

    // MARK: - BUG 2 (a): strict mixer-window binding
    //
    // BOTH the Mixer window and the arrange window contain an `AXLayoutArea description="Mixer"`
    // — the arrange one is the Inspector's MINI-MIXER (selected track + its output). With the
    // Mixer window CLOSED it is the only one left, and binding it silently REPLACES the shadow
    // model with 2 strips while reporting success. Bind only inside a window titled "…Mixer…".

    func testStripHandlesBindsTheMixerWindowNotTheInspector() async throws {
        let bridge = AXBridge(provider: AXFixture.provider("strip_special"))
        let names = try await bridge.stripHandles().map(\.name)
        XCTAssertEqual(names, ["Liverpool", "Inst 2", "Aux 1", "Stereo Out", "Master"])
    }

    func testMixerWindowClosedThrowsInsteadOfBindingMiniMixer() async throws {
        let p = AXFixture.provider("strip_special")
        p.rootNode.children.removeAll { $0.title == "Untitled 1 - Mixer: Tracks" }   // user closed the Mixer
        let bridge = AXBridge(provider: p)
        do {
            let names = try await bridge.stripHandles().map(\.name)
            XCTFail("expected 'no mixer surface'; instead bound the Inspector mini-mixer: \(names)")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("no mixer surface"), f.error)
        }
    }

    func testHasMixerWindowReflectsWhetherTheMixerWindowIsOpen() async throws {
        let p = AXFixture.provider("strip_special")
        let bridge = AXBridge(provider: p)
        let whileOpen = await bridge.hasMixerWindow()
        XCTAssertTrue(whileOpen)
        p.rootNode.children.removeAll { $0.title == "Untitled 1 - Mixer: Tracks" }
        let whileClosed = await bridge.hasMixerWindow()
        XCTAssertFalse(whileClosed, "the Inspector's mini-mixer must NOT count as a Mixer window")
    }

    /// A plugin window that starts in Editor view; pressing view→Controls swaps title to "Controls".
    func testSwitchToControlsPressesMenuItem() async throws {
        let controlsItem = FakeAXNode(role: "AXMenuItem", title: "Controls")
        let editorItem   = FakeAXNode(role: "AXMenuItem", title: "Editor")
        let menu = FakeAXNode(role: "AXMenu", children: [controlsItem, editorItem])
        let viewBtn = FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor",
                                 children: [menu])
        controlsItem.onPress = { viewBtn.title = "Controls" }   // Logic reflects the choice
        let window = FakeAXNode(role: "AXWindow", title: "vox", children: [
            FakeAXNode(role: "AXButton", description: "close"), viewBtn,
        ])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let windows = await bridge.windowsForTest()
        let h = try XCTUnwrap(windows.first)
        try await bridge.switchToControlsView(h)
        let title = await bridge.titleForViewMenuTest(h)
        XCTAssertEqual(title, "Controls")
    }

    /// An opaque plugin (no AXSlider anywhere) must still be found as a plugin window.
    func testPluginWindowDetectsOpaqueWindow() async throws {
        let window = FakeAXNode(role: "AXWindow", title: "guitar", children: [
            FakeAXNode(role: "AXButton", description: "close"),
            FakeAXNode(role: "AXMenuButton", description: "view", title: "Editor"),
            FakeAXNode(role: "AXGroup", subrole: "AXUnknown", title: "SomeAU"),  // opaque, no slider
        ])
        let bridge = AXBridge(provider: FakeAXProvider(root:
            FakeAXNode(role: "AXApplication", children: [window])))
        let found = await bridge.pluginWindow(track: "guitar")
        XCTAssertNotNil(found, "an opaque plugin window (no slider) must still be detected")
    }
}
