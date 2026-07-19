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

    // MARK: - delete_track (DISABLED — Phase 5 Task 0 confirmed the AX selection wall)
    //
    // Old safety model (Fixtures/ax/selection.txt, resolved 2026-07-13): AX could not change
    // Logic's track selection at all, so `delete_track` was permanently DISABLED — a tool that
    // pressed a strip and then "Delete Track" would delete whatever track the user last selected
    // in Logic, not the requested one — a wrong-track destructive bug caught live on real Logic.
    // A Phase 5 re-enable attempt (via a confirmed Has-Focus press) was tried, but a live Task 0
    // probe proved the arrange header's Has Focus control is a read-only status indicator —
    // AXPress on it is a no-op — so selection genuinely cannot be confirmed via AX. delete_track
    // stays permanently disabled; see `testDeleteTrackIsDisabled` below.

    /// Mixer-only fixture (no arrange window) — used just to exercise `Edit ▸ Undo` restoring a
    /// strip that `Track ▸ Delete Track` removed, entirely through `daemon.menu` (bypassing
    /// `DeleteTrackTool`, whose confirm guard needs an arrange window this fixture doesn't build).
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

    /// undo_structural just drives Edit ▸ Undo and settle-polls the track list — exercise the
    /// deletion+undo sequence directly through `daemon.menu` (bypassing `DeleteTrackTool`'s
    /// confirm guard, which needs an arrange window this fixture doesn't build) so
    /// undo_structural's own behavior stays covered independent of delete_track's selection story.
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

    /// Fixture for the zero-actuation tests below: a mixer with strips ["vox", "Rugrats"] AND a
    /// `Track ▸ Delete Track` menu item WIRED to actually remove "Rugrats" from the mixer
    /// `AXLayoutArea "Mixer"` on press — mirrors `provider()`'s menu-wiring pattern above, just for
    /// "Delete Track" instead of "New Audio Track". If `DeleteTrackTool` ever regressed into
    /// actually pressing Delete Track (defeating its own guard), this wiring makes that visible as
    /// a strip disappearing — a silent "throws but presses anyway" bug wouldn't be caught by
    /// asserting the throw alone.
    func providerWithWiredDeleteTrackMenu() -> FakeAXProvider {
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"),
            FakeAXNode(role: "AXLayoutItem", description: "Rugrats"),
        ])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let deleteItem = FakeAXNode(role: "AXMenuItem", title: "Delete Track")
        deleteItem.onPress = { area.children.removeAll { $0.description == "Rugrats" } }
        let menu = FakeAXNode(role: "AXMenu", children: [deleteItem])
        p.menuBarNode = FakeAXNode(role: "AXMenuBar",
            children: [FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])])
        return p
    }

    /// delete_track is permanently disabled (Task 0: AX cannot confirm track selection) — it must
    /// always throw a `layer: "ax"` ToolFailure and never touch the mixer, even for a known track.
    /// Zero actuation is the load-bearing assertion: the fixture's "Delete Track" menu item WOULD
    /// remove "Rugrats" if pressed, so the guard failing would show up as the strip vanishing.
    func testDeleteTrackIsDisabled() async throws {
        let d = await daemon(providerWithWiredDeleteTrackMenu())
        do {
            _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("Rugrats")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
        }
        let names = try await currentTrackNames(d)
        XCTAssertTrue(names.contains("Rugrats"), "delete_track must press nothing — 'Rugrats' should still be in the mixer")
    }

    /// delete_track resolves the track via `mixerStrip(named:)` BEFORE throwing its "not available"
    /// error, so an unknown name should surface `AXBridge.find`'s own `layer: "ax"` error instead of
    /// silently swallowing it — restores the unknown-name coverage dropped when this test was
    /// trimmed to a bare throw check.
    func testDeleteTrackUnknownNameStillThrowsAXError() async throws {
        let d = await daemon(providerWithWiredDeleteTrackMenu())
        do {
            _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("nope")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
        }
    }

    // MARK: - set_output (SEARCH-driven routing popup)
    //
    // Ground truth: Fixtures/ax/popup_output.txt + the live `axdump outputprobe` capture (2026-07-15).
    // The strip's output button (an AXButton whose description IS the current destination, e.g.
    // "Bus 9") supports AXPress only. Pressing it opens a routing popup that — exactly like the
    // plugin-insert popup — attaches as a SIBLING OF THE MIXER STRIPS (a child of the mixer
    // AXLayoutArea, NOT under the button, so `menuItems(under: button)` finds nothing) and whose
    // FIRST item wraps an `AXTextField subrole="AXSearchField"`. `setString(dest)` FILTERS the popup:
    // the nested "Bus ▸"/"Output ▸" submenus FLATTEN to a top-level list of every destination whose
    // title CONTAINS the query — so typing "Bus 3" also yields "Bus 30"/"Bus 13"/"Bus 31", and
    // grabbing the first result would route to the WRONG bus. Pressing a destination mutates the
    // output button's own description (mirroring Logic updating the displayed destination).
    func providerWithOutputPopup(current: String = "Bus 9", destLatency: Int = 0,
                                 staleStripOnSelect: Bool = false)
        -> (p: FakeAXProvider, outputButton: FakeAXNode, search: FakeAXNode) {
        let outputButton = FakeAXNode(role: "AXButton", description: current)
        // The routing slot is identified STRUCTURALLY — the plain AXButton immediately after the
        // strip's "group" popup (Fixtures/ax/strip_special.txt) — so the fake carries that anchor.
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
            FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"), outputButton,
        ])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))

        // The popup's FIRST item wraps a settable AXSearchField (like the real routing/insert popup).
        let search = FakeAXNode(role: "AXTextField", subrole: "AXSearchField", settable: true,
                                children: [FakeAXNode(role: "AXButton")])
        let searchItem = FakeAXNode(role: "AXMenuItem", children: [search])

        func dest(_ name: String) -> FakeAXNode {
            let item = FakeAXNode(role: "AXMenuItem", title: name)
            item.onPress = {
                if staleStripOnSelect {
                    // Model Logic RE-RENDERING the strip on a routing change (real Logic also inserts
                    // an Aux for a fresh bus, shifting indices): the AXLayoutItem handle captured
                    // before the press is now detached and still shows the OLD output; a FRESH strip
                    // of the same name carries the new destination. Only re-resolving by NAME confirms.
                    let fresh = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [
                        FakeAXNode(role: "AXPopUpButton", description: "group", title: "group"),
                        FakeAXNode(role: "AXButton", description: name),
                    ])
                    area.children.removeAll { $0 === strip }
                    area.children.append(fresh)
                } else if destLatency > 0 {
                    outputButton.scheduleDescriptionChange(to: name, afterReads: destLatency)
                } else {
                    outputButton.description = name
                }
            }
            return item
        }
        // Catalog order deliberately puts PARTIAL matches ("Bus 30", "Bus 13") BEFORE the exact
        // "Bus 3", so a grab-the-first-result bug would route to the wrong bus and be caught.
        let catalog = ["No Output", "Stereo Output", "Bus 1", "Bus 30", "Bus 13", "Bus 3", "Bus 31"].map(dest)

        // The popup is an AXMenu whose children are computed by a `dynamicChildren` FILTER keyed on
        // the search field's current value — the load-bearing bit that makes these tests
        // non-tautological: before typing only the search field shows; after typing, the flat list
        // of CONTAINS-matches (see catalog order above).
        let popup = FakeAXNode(role: "AXMenu", children: [searchItem])
        popup.dynamicChildren = {
            let q = search.stringValue ?? ""
            if q.isEmpty { return [searchItem] }
            return [searchItem] + catalog.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) }
        }
        // Pressing the output button opens the popup as a SIBLING of the strips (child of the area);
        // cancel dismisses it — exactly the plugin-insert popup shape.
        outputButton.onPress = { if !area.children.contains(where: { $0 === popup }) { area.children.append(popup) } }
        outputButton.onCancel = { area.children.removeAll { $0 === popup } }
        return (p, outputButton, search)
    }

    /// HAPPY PATH + type-then-select oracle: the tool must find the popup by walking the WINDOW tree
    /// (it is a SIBLING of the strips, NOT under the button — the old `menuItems(under: button)` code
    /// found nothing on real Logic), TYPE "Bus 3" into the search field, pick the EXACT filtered
    /// match, press it, and confirm via the strip's output slot.
    func testSetOutputTypesDestAndSelectsExactMatch() async throws {
        let (p, _, search) = providerWithOutputPopup()
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("vox"))
        XCTAssertEqual(o["output"], .string("Bus 3"))
        XCTAssertEqual(search.setStringLog, ["Bus 3"], "the driver must TYPE the dest into the routing search field")
    }

    /// EXACT-MATCH DISCIPLINE: filtering "Bus 3" also returns "Bus 30"/"Bus 13"/"Bus 31" (listed
    /// BEFORE the exact match in the catalog). Grabbing the first result would route to the WRONG
    /// bus; the tool must press the exact title.
    func testSetOutputPicksExactMatchNotFirstFilteredPartial() async throws {
        let (p, _, _) = providerWithOutputPopup()
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["output"], .string("Bus 3"), "must press the EXACT match, not the first filtered partial")
    }

    /// FALSE-NEGATIVE REGRESSION (real Logic, 2026-07-15): selecting a routing destination re-renders
    /// the strip (routing to a fresh bus even inserts an Aux, shifting indices), INVALIDATING the
    /// AXLayoutItem handle captured before the press. `settleOutput(strip:)` read that stale handle's
    /// output as "unreadable"/old for the full timeout, so set_output returned "output change not
    /// confirmed" for a routing that ACTUALLY LANDED — a false negative. The confirm must re-resolve
    /// the strip by NAME (a fresh mixer walk). Here pressing "Bus 3" REPLACES the strip node; the
    /// pre-press handle stays "Bus 9", only a re-find sees "Bus 3".
    func testSetOutputConfirmsAfterStripHandleGoesStale() async throws {
        let (p, _, _) = providerWithOutputPopup(staleStripOnSelect: true)
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail("set_output should CONFIRM via a re-find, not false-negative") }
        XCTAssertEqual(o["output"], .string("Bus 3"))
    }

    /// SETTLE-POLL through async AX lag: pressing the dest schedules the output button's description
    /// to change only after several `.description` reads, so `settleOutput` must poll it out rather
    /// than trust an immediate read (afterReads:8 — read() probes the description ~6× per call).
    func testSetOutputSettlesThroughAsyncLag() async throws {
        let (p, _, _) = providerWithOutputPopup(destLatency: 8)
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 3")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["output"], .string("Bus 3"), "settleOutput should poll until the async description change lands")
    }

    func testSetOutputTopLevelDestWorks() async throws {
        let (p, _, _) = providerWithOutputPopup()
        let d = await daemon(p)
        let r = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("No Output")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["output"], .string("No Output"))
    }

    func testSetOutputUnknownDestThrowsAX() async throws {
        let (p, _, _) = providerWithOutputPopup()
        let d = await daemon(p)
        do {
            _ = try await SetOutputTool(daemon: d).invoke(["track": .string("vox"), "dest": .string("Bus 99")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("no routing destination"), "should be the not-found error: \(f.error)")
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
