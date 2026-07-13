import XCTest
import MCP
@testable import LogicMCPCore

final class PluginInsertToolTests: XCTestCase {
    /// Builds a strip with a THREE-level insert popup on its "audio plug-in" slot, per
    /// Fixtures/ax/popup_plugin.txt: top level holds RECENT plugins ("Channel EQ" ▸) AND
    /// categories ("EQ" ▸); a category's submenu holds plugin names ("Vintage EQ" ▸ under "EQ");
    /// a plugin's submenu holds the CHANNEL-CONFIG leaves (Stereo / Dual Mono) — the pressable
    /// leaf, not the plugin name. "Channel EQ" and "Vintage EQ" are DELIBERATELY different names
    /// so a search that only looked at the top level could never find "Vintage EQ" — that's what
    /// makes test (b) below a genuine proof of the one-category-deep descent, not a tautology.
    ///
    /// `configLatency`, when > 0, is passed as `afterReads` to `scheduleChildAppend` on the strip
    /// instead of appending the new plugin group synchronously — used by test (d) to model
    /// Logic's async AX-tree update lag after the popup-leaf press.
    func stripWithPluginPopup(configLatency: Int = 0) -> (p: FakeAXProvider, strip: FakeAXNode, slot: FakeAXNode) {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox")

        func configLeaves(pluginName: String) -> (menu: FakeAXNode, stereo: FakeAXNode) {
            let stereo = FakeAXNode(role: "AXMenuItem", title: "Stereo")
            let dualMono = FakeAXNode(role: "AXMenuItem", title: "Dual Mono")
            stereo.onPress = {
                let group = FakeAXNode(role: "AXGroup", description: pluginName,
                                       children: [FakeAXNode(role: "AXButton", description: "open")])
                strip.scheduleChildAppend(group, afterReads: configLatency)
            }
            return (FakeAXNode(role: "AXMenu", children: [stereo, dualMono]), stereo)
        }

        // Top-level (Recent): "Channel EQ" ▸ [Stereo | Dual Mono]
        let (channelEQSubmenu, _) = configLeaves(pluginName: "Channel EQ")
        let channelEQItem = FakeAXNode(role: "AXMenuItem", title: "Channel EQ", children: [channelEQSubmenu])

        // Category "EQ" ▸ "Vintage EQ" ▸ [Stereo | Dual Mono] — ONE level deeper.
        let (vintageEQSubmenu, _) = configLeaves(pluginName: "Vintage EQ")
        let vintageEQItem = FakeAXNode(role: "AXMenuItem", title: "Vintage EQ", children: [vintageEQSubmenu])
        let eqCategorySubmenu = FakeAXNode(role: "AXMenu", children: [vintageEQItem])
        let eqCategoryItem = FakeAXNode(role: "AXMenuItem", title: "EQ", children: [eqCategorySubmenu])

        let topMenu = FakeAXNode(role: "AXMenu", children: [channelEQItem, eqCategoryItem])
        let slot = FakeAXNode(role: "AXButton", description: "audio plug-in", children: [topMenu])
        strip.children.append(slot)

        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))
        return (p, strip, slot)
    }

    func daemon(_ p: FakeAXProvider) async -> Daemon { await Daemon(wire: InMemoryWire(), axProvider: p) }

    /// (a) A TOP-LEVEL (Recent) plugin is found and its default "Stereo" config leaf pressed;
    /// re-reading `pluginGroups` confirms it landed.
    func testInsertTopLevelRecentPluginSucceeds() async throws {
        let (p, _, _) = stripWithPluginPopup()
        let d = await daemon(p)
        let r = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Channel EQ")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("vox"))
        XCTAssertEqual(o["plugin"], .string("Channel EQ"))
        let strip = try await d.ax.find("vox")
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertTrue(groups.contains("Channel EQ"))
    }

    /// (b) "Vintage EQ" exists ONLY one category ("EQ") deep — it is NOT a top-level item. This
    /// test would FAIL if `selectPluginFromPopup` only scanned the top level (it would report
    /// "plugin 'Vintage EQ' not found"), so it genuinely exercises the nested descent.
    func testInsertPluginFoundOneCategoryDeepSucceeds() async throws {
        let (p, _, _) = stripWithPluginPopup()
        let d = await daemon(p)
        let r = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Vintage EQ")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["plugin"], .string("Vintage EQ"))
        let strip = try await d.ax.find("vox")
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertTrue(groups.contains("Vintage EQ"), "expected the nested (one-category-deep) plugin to be found and inserted")
    }

    /// (c) An unknown plugin name throws a structured layer:"ax" error listing the available
    /// titles (top level + one category deep), and leaves the popup dismissed.
    func testInsertUnknownPluginThrowsAXWithAvailableTitles() async throws {
        let (p, _, _) = stripWithPluginPopup()
        let d = await daemon(p)
        do {
            _ = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Nope Plugin")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.observed?.contains("Channel EQ") ?? false, "should list available titles: \(f.observed ?? "nil")")
        }
    }

    /// (d) Regression test for the settle-poll: pressing the config leaf schedules the new plugin
    /// group's appearance via `scheduleChildAppend(_:afterReads:)` instead of appending it
    /// synchronously, so it stays invisible to `pluginGroups(strip)` reads for a while after the
    /// press — mirroring `testCreateTrackWaitsForAsyncStripAppearance` /
    /// `testSetOutputSettlesThroughAsyncLag`. `AXBridge.pluginGroups(strip)` calls
    /// `children(of: strip)` EXACTLY ONCE per invocation (verified by reading its source: unlike
    /// `AXBridge.read(strip)`, which probes a strip's children ~6x via four `control()` calls plus
    /// the output-button scan, `pluginGroups` calls `p.children(of: strip)` a single time up front
    /// and only recurses into EACH CANDIDATE GROUP's own children, never re-reading the strip's
    /// children a second time). So `afterReads: 2` is the smallest value that is NOT tautological
    /// here: the settle helper's first (immediate, pre-sleep) call decrements the countdown from 2
    /// to 1 and still sees the stale (pre-insert) group list, so the condition is false and the
    /// poll loop's `Task.sleep` + retry must actually run before the second call decrements 1 to 0
    /// and reveals the new group. `afterReads: 1` would reveal it on that very first call and prove
    /// nothing about the poll loop. Against a `settlePlugins` reduced to a single immediate read
    /// (no loop) this test FAILS with "plugin insert not confirmed" (verified by temporarily
    /// commenting out the poll loop's `while` body); the real settle-poll waits it out and succeeds.
    func testInsertPluginSettlesThroughAsyncLag() async throws {
        let (p, _, _) = stripWithPluginPopup(configLatency: 2)
        let d = await daemon(p)
        let r = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Channel EQ")])
        guard case .object(let o) = r else { return XCTFail() }
        XCTAssertEqual(o["plugin"], .string("Channel EQ"), "settlePlugins should poll until the async group-append lands")
    }
}
