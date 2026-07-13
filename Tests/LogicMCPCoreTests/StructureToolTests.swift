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
        let window = FakeAXNode(role: "AXWindow", children: [area])
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
        let window = FakeAXNode(role: "AXWindow", children: [area])
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

    /// select_track had zero coverage before this. Confirms it resolves case-insensitively /
    /// by unique prefix, actually performs an AXPress on the resolved strip (not just a find()),
    /// and returns the resolved (canonical) name rather than echoing the input.
    func testSelectTrackPressesAndReturnsResolvedName() async throws {
        let vox = FakeAXNode(role: "AXLayoutItem", description: "Vocals")
        var pressed = false
        vox.onPress = { pressed = true }
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [vox])
        let window = FakeAXNode(role: "AXWindow", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        let d = await daemon(p)
        let r = try await SelectTrackTool(daemon: d).invoke(["name": .string("vo")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["selected"], .string("Vocals"))
        XCTAssertTrue(pressed, "select_track should press the resolved strip")
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
    // Safety model (Fixtures/ax/checkpoint.txt): Save/Save As/Save A Copy As/Project
    // Alternatives are ALL disabled in real Logic, so delete_track does NOT auto-checkpoint.
    // Its safety is that structural ops are reversible via Logic-native Edit ▸ Undo (proven on
    // real Logic: create_track then Edit ▸ Undo cleanly restored the strip count). These fakes
    // model that: pressing the "scratch" strip records it as the current selection (mirroring
    // Logic acting on "the selected track"); pressing "Delete Track" removes the selection from
    // the mixer AXLayoutArea; pressing "Undo" (providerDeletableWithUndo only) re-appends it.

    /// Track ▸ Delete Track removes the currently-selected strip from the mixer area.
    func providerDeletable(_ trackName: String) -> FakeAXProvider {
        let scratch = FakeAXNode(role: "AXLayoutItem", description: trackName)
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [
            FakeAXNode(role: "AXLayoutItem", description: "vox"), scratch,
        ])
        let window = FakeAXNode(role: "AXWindow", children: [area])
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
        let window = FakeAXNode(role: "AXWindow", children: [area])
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

    func testDeleteTrackRemovesStrip() async throws {
        // fake: press "Delete Track" removes the selected strip from the mixer area
        let d = await daemon(providerDeletable("scratch"))
        _ = try await d.axMixer.syncTracks()
        let r = try await DeleteTrackTool(daemon: d).invoke(["name": .string("scratch")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["deleted"], .string("scratch"))
        let names = try await currentTrackNames(d)
        XCTAssertFalse(names.contains("scratch"))
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

    func testUndoStructuralRestores() async throws {
        // fake: press "Undo" re-adds the last removed strip
        let d = await daemon(providerDeletableWithUndo("scratch"))
        _ = try await d.axMixer.syncTracks()
        _ = try await DeleteTrackTool(daemon: d).invoke(["name": .string("scratch")])
        _ = try await UndoStructuralTool(daemon: d).invoke([:])
        let names = try await currentTrackNames(d)
        XCTAssertTrue(names.contains("scratch"))
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

        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [outputButton])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", children: [area])
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
    /// `control(strip, description:)` probes for volume/mute/solo/pan each scan the strip's only
    /// child — this button — plus `outputButton`'s by-exclusion scan and `AXBridge.read`'s final
    /// fetch), so `afterReads: 8` guarantees the change is still hidden through the whole first
    /// `read(strip)` call and only lands on the second (i.e. after a real 50ms sleep + retry).
    /// Against a `settleOutput` reduced to a single immediate read this test FAILS with "output
    /// change not confirmed", observed "Bus 9" (verified by stashing the fix — see task report for
    /// the RED transcript); the real settle-poll waits it out and succeeds.
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

        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [outputButton])
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", children: [area])
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
}
