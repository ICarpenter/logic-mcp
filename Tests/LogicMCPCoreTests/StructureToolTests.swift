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
}
