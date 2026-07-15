import XCTest
import MCP
@testable import LogicMCPCore

final class StructureToolTests: XCTestCase {
    /// Menu bar + a mixer area; pressing "New Audio Track" appends an "Audio 1" strip to the area,
    /// so create_track's verify (AXMixer.syncTracks) sees it.
    func provider() -> FakeAXProvider {
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"),
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let newAudio = FakeAXNode(role: "AXMenuItem", title: "New Audio Track")
        newAudio.onPress = {
            area.children.append(FakeAXNode(role: "AXLayoutItem", description: "Audio 1"))
        }
        let menu = FakeAXNode(role: "AXMenu", children: [newAudio])
        p.menuBarNode = FakeAXNode(role: "AXMenuBar",
            children: [FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])])
        return p
    }
    func daemon(_ p: FakeAXProvider) async -> Daemon { await Daemon(wire: InMemoryWire(), axProvider: p) }

    func testCreateAudioTrackAppearsInMixer() async throws {
        let d = await daemon(provider())
        let r = try await CreateTrackTool(daemon: d).invoke(["kind": .string("audio")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["created"], .bool(true))
        let names = await d.model.snapshot.tracks.map(\.name)
        XCTAssertTrue(names.contains("Audio 1"), "new strip should appear on re-read")
    }

    func testCreateUnknownKindErrors() async throws {
        let d = await daemon(provider())
        do { _ = try await CreateTrackTool(daemon: d).invoke(["kind": .string("banjo")]); XCTFail() }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "daemon") }
    }

    /// Regression test for the settle-poll fix: Logic's AX tree updates ASYNCHRONOUSLY after a
    /// menu press (real-Logic probe: ~700ms before a new strip was visible), so `create_track`
    /// must not trust a single immediate re-read. This fake models that lag directly: the new
    /// "Audio 1" strip is scheduled via `scheduleChildAppend(_:afterReads:)` and stays invisible
    /// to `children(of: area)` reads for 2 reads after the press, becoming visible only on the
    /// 3rd. Against the pre-fix immediate-read code this test FAILS with "track creation not
    /// confirmed" (verified by stashing the fix); the settle-poll waits it out and succeeds.
    func testCreateTrackWaitsForAsyncStripAppearance() async throws {
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"),
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let newAudio = FakeAXNode(role: "AXMenuItem", title: "New Audio Track")
        newAudio.onPress = {
            area.scheduleChildAppend(FakeAXNode(role: "AXLayoutItem", description: "Audio 1"), afterReads: 2)
        }
        let menu = FakeAXNode(role: "AXMenu", children: [newAudio])
        p.menuBarNode = FakeAXNode(role: "AXMenuBar",
            children: [FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])])
        let d = await daemon(p)
        let r = try await CreateTrackTool(daemon: d).invoke(["kind": .string("audio")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["created"], .bool(true))
        XCTAssertEqual(o["track"], .string("Audio 1"))
    }

    /// rename_track is deferred (Fixtures/ax/rename.txt: AXSetValue on Logic's track-name fields
    /// is cosmetic-only and never commits) — it must resolve the track via AXBridge.find() FIRST
    /// (so a bad name still gets the precise `layer:"ax"` find() error) and then always throw the
    /// structured "not available" error, the same honest pattern as Phase 2's set_send.
    func testRenameTrackReturnsNotAvailableError() async throws {
        let d = await daemon(provider())
        do {
            _ = try await RenameTrackTool(daemon: d).invoke(["track": .string("vox"), "to": .string("lead vox")])
            XCTFail("expected a not-available ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("not available"))
        }
    }

    func testRenameTrackUnknownTrackStillErrorsClearly() async throws {
        let d = await daemon(provider())
        do {
            _ = try await RenameTrackTool(daemon: d).invoke(["track": .string("nope"), "to": .string("lead vox")])
            XCTFail("expected a track-not-found ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")   // find() throws layer:"ax" for unknown track
            XCTAssertFalse(f.error.contains("not available"), "unknown-track error should be find()'s, not the deferred-rename error")
        }
    }

    // MARK: - delete_track / undo_structural
    //
    // Safety model (Fixtures/ax/selection.txt, resolved 2026-07-13): AX cannot change Logic's
    // track selection — AXPress on a mixer strip is unsupported (-25200) and
    // AXSetValue(AXSelected) returns success while changing nothing. Since `Track ▸ Delete Track`
    // deletes the SELECTED track, a tool that pressed a strip and then Delete Track would delete
    // whatever track the user last selected in Logic, not the requested one — a wrong-track
    // destructive bug caught live on real Logic. `delete_track` is therefore DISABLED: it always
    // throws a structured error and must never press the strip or "Track ▸ Delete Track" at all.
    // These fakes still model the (never-invoked-by-the-tool) press sequence that WOULD delete —
    // pressing the "scratch" strip records it as the current selection, and pressing "Delete
    // Track" removes the selection from the mixer AXLayoutArea — so the "nothing was removed"
    // regression guard below is actually exercising a fake that COULD delete, proving the guard
    // would fail if delete_track were re-enabled.

    /// Track ▸ Delete Track removes the currently-selected strip from the mixer area.
    func providerDeletable(_ trackName: String) -> FakeAXProvider {
        let scratch = FakeAXNode(role: "AXLayoutItem", description: trackName)
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"), scratch,
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        var selected: FakeAXNode?
        scratch.onPress = { selected = scratch }
        p.makeMenuBar([
            (bar: "Track", items: [(title: "Delete Track", onPress: {
                if let s = selected { area.children.removeAll { $0 === s } }
            })]),
        ])
        return p
    }

    /// Same as `providerDeletable`, plus Edit ▸ Undo re-appends whichever strip "Delete Track"
    /// last removed.
    func providerDeletableWithUndo(_ trackName: String) -> FakeAXProvider {
        let scratch = FakeAXNode(role: "AXLayoutItem", description: trackName)
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"), scratch,
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        var selected: FakeAXNode?
        scratch.onPress = { selected = scratch }
        p.makeMenuBar([
            (bar: "Track", items: [(title: "Delete Track", onPress: {
                if let s = selected { area.children.removeAll { $0 === s } }
            })]),
            (bar: "Edit", items: [(title: "Undo", onPress: {
                if let s = selected, !area.children.contains(where: { $0 === s }) {
                    area.children.append(s)
                }
            })]),
        ])
        return p
    }

    /// THE regression guard: delete_track must NEVER delete, because AX cannot select a track
    /// (selection.txt) and `Track ▸ Delete Track` acts on whatever IS selected. `providerDeletable`
    /// models a fake that WOULD delete "scratch" if the tool pressed the strip then "Delete
    /// Track" — so asserting the strip survives is a real guard, not a vacuous one: if
    /// `delete_track` were re-enabled to press-then-delete, this assertion would fail.
    func testDeleteTrackNeverDeletes() async throws {
        var deletePressed = false
        let p = providerDeletable("scratch")
        // Instrument the fake's "Delete Track" menu item so we can also assert it was never
        // reached at all, not just that its effect (strip removal) didn't happen.
        if let bar = p.menuBarNode {
            for barItem in bar.children where barItem.title == "Track" {
                for menu in barItem.children {
                    for item in menu.children where item.title == "Delete Track" {
                        let original = item.onPress
                        item.onPress = { deletePressed = true; original?() }
                    }
                }
            }
        }
        let d = await daemon(p)
        let namesBefore = try await d.axMixer.syncTracks()
        do {
            _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("scratch")])
            XCTFail("expected a not-available ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("not available"), "error should say delete_track is not available: \(f.error)")
        }
        XCTAssertFalse(deletePressed, "delete_track must never press Track ▸ Delete Track")
        let namesAfter = try await currentTrackNames(d)
        XCTAssertEqual(namesAfter, namesBefore, "delete_track must not change the mixer's track list")
        XCTAssertTrue(namesAfter.contains("scratch"), "the target track must still be present after delete_track")
    }

    func testDeleteTrackUnknownTrackErrorsAX() async throws {
        let d = await daemon(providerDeletable("scratch"))
        _ = try await d.axMixer.syncTracks()
        do {
            _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("nope")])
            XCTFail("expected a track-not-found ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")   // find() throws layer:"ax" for unknown track
        }
    }

    /// undo_structural is unaffected by the delete_track disable — it just drives Edit ▸ Undo and
    /// settle-polls the track list. Since delete_track itself no longer presses anything, this
    /// test exercises the deletion+undo sequence directly through `daemon.menu` (bypassing the
    /// now-disabled tool) so undo_structural's own behavior stays covered.
    func testUndoStructuralRestores() async throws {
        // fake: pressing "scratch" selects it, pressing "Delete Track" removes the selection,
        // pressing "Undo" re-adds the last removed strip.
        let d = await daemon(providerDeletableWithUndo("scratch"))
        let strip = try await d.ax.find("scratch")
        _ = try await d.axMixer.syncTracks()
        try await d.menu.pressElement(strip)
        try await d.menu.pressMenuPath(["Track", "Delete Track"])
        var names = try await currentTrackNames(d)
        XCTAssertFalse(names.contains("scratch"), "test setup should have removed 'scratch' before exercising undo")
        _ = try await UndoStructuralTool(daemon: d).invoke([:])
        names = try await currentTrackNames(d)
        XCTAssertTrue(names.contains("scratch"), "undo_structural should restore the deleted strip")
    }

    // MARK: - set_output (NESTED routing popup)
    //
    // Ground truth: Fixtures/ax/popup_output.txt (real Logic, backgrounded). The strip's output
    // button (an AXButton whose description IS the current destination, e.g. "Bus 9") supports
    // AXPress only — pressing it opens a popup whose AXMenu tree is NESTED: top level holds
    // "No Output" plus "Output ▸"/"Bus ▸" submenus; real destinations ("Bus 3", "Stereo Output")
    // are leaves one submenu deep. This models that shape: the button's child AXMenu has
    // top-level items "No Output"/"Output"(submenu: "Stereo Output")/"Bus"(submenu: "Bus 1","Bus 3"),
    // and pressing a leaf mutates the output button's OWN description in place (mirroring Logic
    // updating the strip's displayed destination once the popup selection lands).
    func providerWithOutputPopup(current: String = "Bus 9") -> (p: FakeAXProvider, outputButton: FakeAXNode) {
        let outputButton = FakeAXNode(role: "AXButton", description: current)

        let noOutput = FakeAXNode(role: "AXMenuItem", title: "No Output")
        noOutput.onPress = { outputButton.description = "No Output" }

        let stereoOut = FakeAXNode(role: "AXMenuItem", title: "Stereo Output")
        let outputSubmenu = FakeAXNode(role: "AXMenu", children: [stereoOut])
        let outputItem = FakeAXNode(role: "AXMenuItem", title: "Output", children: [outputSubmenu])

        let bus1 = FakeAXNode(role: "AXMenuItem", title: "Bus 1")
        let bus3 = FakeAXNode(role: "AXMenuItem", title: "Bus 3")
        bus3.onPress = { outputButton.description = "Bus 3" }
        let busSubmenu = FakeAXNode(role: "AXMenu", children: [bus1, bus3])
        let busItem = FakeAXNode(role: "AXMenuItem", title: "Bus", children: [busSubmenu])

        let topMenu = FakeAXNode(role: "AXMenu", children: [noOutput, outputItem, busItem])
        outputButton.children = [topMenu]

        // The routing slot is identified STRUCTURALLY — the plain AXButton immediately after the
        // strip's "group" popup (Fixtures/ax/strip_special.txt) — so the fake carries that anchor.
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"), outputButton,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        return (p, outputButton)
    }

    func testSetOutputSelectsSubmenuLeafAndConfirms() async throws {
        let (p, _) = providerWithOutputPopup()
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("vox"))
        XCTAssertEqual(o["output"], .string("Bus 3"))
    }

    /// Regression test for the settle-poll fix, mirroring `testCreateTrackWaitsForAsyncStripAppearance`
    /// for `settleOutput`: all THREE other set_output tests mutate the output button's description
    /// SYNCHRONOUSLY inside `onPress` (`providerWithOutputPopup` above), so `settleOutput`'s immediate
    /// first read always satisfies the condition and the poll loop/sleep/deadline logic is never
    /// exercised. This fake models the async lag directly: pressing "Bus 3" schedules the output
    /// button's description to become "Bus 3" via `scheduleDescriptionChange(to:afterReads:)` instead
    /// of mutating it in place, so it stays "Bus 9" for several `.description` reads after the press.
    /// Each `AXBridge.read(strip)` call reads the button's `.description` SIX times (the four
    /// `control(strip, description:)` probes for volume/mute/solo/pan each scan the strip's
    /// children until they miss — reaching this button every time — plus `outputButton`'s
    /// structural match and `AXBridge.read`'s final fetch), so `afterReads: 8` guarantees the
    /// change is still hidden through the whole first `read(strip)` call and only lands on the
    /// second (i.e. after a real 50ms sleep + retry). Against a `settleOutput` reduced to a single
    /// immediate read this test FAILS with "output change not confirmed", observed "Bus 9"
    /// (verified by stashing the fix); the real settle-poll waits it out and succeeds.
    func testSetOutputSettlesThroughAsyncLag() async throws {
        let outputButton = FakeAXNode(role: "AXButton", description: "Bus 9")
        let bus1 = FakeAXNode(role: "AXMenuItem", title: "Bus 1")
        let bus3 = FakeAXNode(role: "AXMenuItem", title: "Bus 3")
        bus3.onPress = { outputButton.scheduleDescriptionChange(to: "Bus 3", afterReads: 8) }
        let busSubmenu = FakeAXNode(role: "AXMenu", children: [bus1, bus3])
        let busItem = FakeAXNode(role: "AXMenuItem", title: "Bus", children: [busSubmenu])
        let noOutput = FakeAXNode(role: "AXMenuItem", title: "No Output")
        let topMenu = FakeAXNode(role: "AXMenu", children: [noOutput, busItem])
        outputButton.children = [topMenu]

        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"), outputButton,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("vox"))
        XCTAssertEqual(o["output"], .string("Bus 3"), "settleOutput should poll until the async description change lands")
    }

    func testSetOutputTopLevelDestWorks() async throws {
        let (p, _) = providerWithOutputPopup()
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("No Output")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["output"], .string("No Output"))
    }

    func testSetOutputUnknownDestThrowsAXWithAvailableTitles() async throws {
        let (p, _) = providerWithOutputPopup()
        let d = await daemon(p)
        do {
            _ = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 99")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.observed?.contains("Bus 3") ?? false, "should list available destinations: \(f.observed ?? "nil")")
        }
    }

    /// BUG 1's consequence for the WRITE path: `Stereo Out` has no routing slot at all
    /// (Fixtures/ax/strip_special.txt). The old by-exclusion search handed set_output the
    /// "bounce" AXSwitch — so this tool would have PRESSED BOUNCE. It must refuse cleanly and
    /// press nothing.
    func testSetOutputOnAStripWithNoOutputSlotRefusesAndPressesNothing() async throws {
        let p = AXFixture.provider("strip_special")
        let bounce = AXFixture.find([p.rootNode], description: "bounce")!
        var bouncePressed = false
        bounce.onPress = { bouncePressed = true }
        let d = await daemon(p)
        do {
            _ = try await SetOutputTool(daemon: d).invoke(["track": .string("Stereo Out"),
                                                           "dest": .string("Bus 3")])
            XCTFail("expected a 'no output slot' ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("no output slot"), f.error)
        }
        XCTAssertFalse(bouncePressed, "set_output must never press an unrelated mixer-panel button")
        XCTAssertEqual(bounce.stringValue, "off", "bounce must still be off")
    }

    // MARK: - BUG 3: Logic RETITLES the Undo menu item per operation
    //
    // "Undo Create Track", "Undo Delete Tracks", "Redo Create Track" — matching the literal title
    // "Undo" by equality worked exactly once and then failed forever with "menu item 'Undo' not
    // found". Match by PREFIX (opt-in, undo/redo only — `pressMenuPath` stays exact so
    // "New Audio Track" can never hit "New Audio Track With Duplicate Settings"), and return the
    // FULL matched title so the caller learns what Logic actually reverted.

    /// Edit ▸ "Undo Create Track" — a fake modeled on the real retitled item.
    func providerWithRetitledUndo(_ undoTitle: String,
                                  extraEditItemsBefore: [String] = []) -> FakeAXProvider {
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"),
            FakeAXNode(role: "AXLayoutItem", description: "Audio 1"),
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        var items: [(title: String, onPress: (() -> Void)?)] = extraEditItemsBefore.map { title in
            (title: title, onPress: { XCTFail("pressed the wrong Edit item: '\(title)'") })
        }
        items.append((title: undoTitle, onPress: {
            area.children.removeAll { $0.description == "Audio 1" }   // Logic reverses the create
        }))
        p.makeMenuBar([(bar: "Edit", items: items)])
        return p
    }

    func testUndoStructuralMatchesTheRetitledUndoItemAndReportsIt() async throws {
        let d = await daemon(providerWithRetitledUndo("Undo Create Track"))
        _ = try await d.axMixer.syncTracks()
        let r = try await UndoStructuralTool(daemon: d).invoke([:])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["undone"], .string("Undo Create Track"),
                       "must report the FULL title Logic showed — our independent oracle of what was reverted")
        let names = try await currentTrackNames(d)
        XCTAssertFalse(names.contains("Audio 1"), "Edit ▸ Undo Create Track should have removed the strip")
    }

    /// The prefix match must not be sloppy: Logic's Edit menu also carries "Undo History…" (a
    /// DIALOG item, ellipsis). Pressing that would open a window instead of undoing anything.
    /// Placed FIRST so a naive `hasPrefix("Undo")` + `first(where:)` picks it — the fake's XCTFail
    /// fires if it does.
    func testUndoStructuralSkipsTheUndoHistoryDialogItem() async throws {
        let d = await daemon(providerWithRetitledUndo("Undo Delete Tracks",
                                                      extraEditItemsBefore: ["Undo History…"]))
        _ = try await d.axMixer.syncTracks()
        let r = try await UndoStructuralTool(daemon: d).invoke([:])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["undone"], .string("Undo Delete Tracks"))
    }
}
