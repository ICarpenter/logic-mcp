import XCTest
import MCP
@testable import LogicMCPCore

final class PluginInsertToolTests: XCTestCase {
    /// Everything a test needs to poke at the search-popup fixture.
    struct Rig {
        let p: FakeAXProvider
        let strip: FakeAXNode
        let slot: FakeAXNode
        let area: FakeAXNode
        let search: FakeAXNode    // the AXSearchField the driver must type into
    }

    /// Builds a mixer window holding a single "vox" strip whose "audio plug-in" slot, WHEN PRESSED,
    /// opens a search popup as a SIBLING OF THE STRIPS (a child of the mixer AXLayoutArea) — the real
    /// structure from Fixtures/ax/popup_plugin_search.txt, NOT a menu under the pressed button.
    ///
    /// The popup is an AXMenu whose first item wraps an AXSearchField and whose remaining items are
    /// plugins. Its children are computed by a `dynamicChildren` FILTER keyed on the search field's
    /// current value — this is the load-bearing bit that makes the tests non-tautological:
    ///   * empty query    -> a small RECENT list that DOES NOT contain the searched plugin, so the
    ///                       tool cannot succeed without TYPING first;
    ///   * non-empty query -> every catalog plugin whose title CONTAINS the query (case-insensitive),
    ///                       in catalog order (a partial like "Squash Compressor" precedes the exact
    ///                       "Compressor"), so grabbing the first result would insert the WRONG plugin.
    /// Pressing a plugin's "Stereo" leaf appends a plugin GROUP named after THAT plugin to the strip —
    /// the independent oracle: the wrong item pressed => the wrong group name => the tool's own
    /// pluginGroups verification fails.
    func rig(configLatency: Int = 0, staleStripOnInsert: Bool = false) -> Rig {
        let strip = FakeAXNode(role: "AXLayoutItem", description: "vox")
        let area = FakeAXNode(role: "AXLayoutArea", description: "Mixer", children: [strip])
        let window = FakeAXNode(role: "AXWindow", title: "mcp_test - Mixer: Tracks", children: [area])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: [window]))

        // --- the search field (a settable AXSearchField), wrapped in its own AXMenuItem ---
        let clearBtn = FakeAXNode(role: "AXButton")
        let search = FakeAXNode(role: "AXTextField", subrole: "AXSearchField", settable: true,
                                children: [clearBtn])
        let searchItem = FakeAXNode(role: "AXMenuItem", children: [search])

        // --- a plugin catalog item: title + submenu of channel-config leaves ("Stereo"/"Dual Mono") ---
        func pluginItem(_ name: String) -> FakeAXNode {
            let stereo = FakeAXNode(role: "AXMenuItem", title: "Stereo")
            let dualMono = FakeAXNode(role: "AXMenuItem", title: "Dual Mono")
            stereo.onPress = {
                let group = FakeAXNode(role: "AXGroup", description: name,
                                       children: [FakeAXNode(role: "AXButton", description: "open")])
                if staleStripOnInsert {
                    // Model Logic RE-CREATING the strip element on insert: the AXLayoutItem handle the
                    // tool captured BEFORE the press is now detached (no plugin group), while a FRESH
                    // strip of the same name carries the group. Only re-resolving the strip by NAME each
                    // poll (not reusing the stale handle) can confirm the insert.
                    let fresh = FakeAXNode(role: "AXLayoutItem", description: "vox", children: [group])
                    area.children.removeAll { $0 === strip }
                    area.children.append(fresh)
                } else {
                    strip.scheduleChildAppend(group, afterReads: configLatency)
                }
            }
            let submenu = FakeAXNode(role: "AXMenu", children: [stereo, dualMono])
            return FakeAXNode(role: "AXMenuItem", title: name, children: [submenu])
        }

        // Catalog order deliberately puts a PARTIAL match ("Squash Compressor") BEFORE the exact
        // "Compressor", so an exact-match-discipline bug (grab first result) would be caught.
        let catalog = ["Squash Compressor", "Compressor", "UAD 4K Buss Compressor",
                       "Channel EQ", "Vintage EQ"].map(pluginItem)
        // Recent (shown before any typing) deliberately EXCLUDES "Compressor" — the tool can only
        // reach it by TYPING and re-reading the FILTERED list. This is what makes setString essential.
        let recent = ["Noise Gate", "Channel EQ"].map(pluginItem)

        let popup = FakeAXNode(role: "AXMenu", children: [searchItem])
        popup.dynamicChildren = {
            let q = search.stringValue ?? ""
            if q.isEmpty { return [searchItem] + recent }
            return [searchItem] + catalog.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) }
        }

        // The slot opens the popup as a SIBLING of the strips on press, and dismisses it on cancel.
        let slot = FakeAXNode(role: "AXButton", description: "audio plug-in")
        slot.onPress = { if !area.children.contains(where: { $0 === popup }) { area.children.append(popup) } }
        slot.onCancel = { area.children.removeAll { $0 === popup } }
        strip.children.append(slot)

        return Rig(p: p, strip: strip, slot: slot, area: area, search: search)
    }

    func daemon(_ p: FakeAXProvider) async -> Daemon { await Daemon(wire: InMemoryWire(), axProvider: p) }

    /// (1) HAPPY PATH + type-then-select oracle: insert "Compressor" — the tool must type the query
    /// into the search field, pick the EXACT filtered match, press its "Stereo" leaf, and confirm via
    /// pluginGroups. Independent oracles: the search field RECORDED a setString of "Compressor", and
    /// the group that landed is named exactly "Compressor".
    func testInsertTypesQueryAndSelectsExactMatch() async throws {
        let r = rig()
        let d = await daemon(r.p)
        let res = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Compressor")])
        guard case .object(let o) = res else { return XCTFail() }
        XCTAssertEqual(o["track"], .string("vox"))
        XCTAssertEqual(o["plugin"], .string("Compressor"))
        XCTAssertEqual(r.search.setStringLog, ["Compressor"], "the driver must TYPE the query into the search field")
        let strip = try await d.ax.find("vox")
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertEqual(groups, ["Compressor"], "the EXACT plugin's leaf must have been pressed")
    }

    /// (2) EXACT-MATCH DISCIPLINE: the filtered results list a PARTIAL ("Squash Compressor") BEFORE
    /// the exact "Compressor". Grabbing the first result would insert "Squash Compressor"; the tool
    /// must select the exact title. Proven by which group lands (pressing the wrong leaf would name
    /// the group "Squash Compressor" and then fail the tool's pluginGroups verification).
    func testInsertPicksExactMatchNotFirstPartial() async throws {
        let r = rig()
        let d = await daemon(r.p)
        _ = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Compressor")])
        let strip = try await d.ax.find("vox")
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertTrue(groups.contains("Compressor"), "the exact match must have been inserted")
        XCTAssertFalse(groups.contains("Squash Compressor"), "must NOT have pressed the first partial match")
    }

    /// (3) NOT FOUND: a query with no exact match throws a structured layer:"ax" error whose
    /// `observed` lists the FILTERED titles actually seen (diagnostic), and the popup is DISMISSED —
    /// no AXMenu left hanging under the mixer area.
    func testInsertUnknownPluginThrowsWithFilteredTitlesAndDismisses() async throws {
        let r = rig()
        let d = await daemon(r.p)
        do {
            _ = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Compress")])
            XCTFail("expected a ToolFailure")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            let obs = f.observed ?? ""
            XCTAssertTrue(obs.contains("Squash Compressor"), "observed should list the FILTERED titles: \(obs)")
            XCTAssertFalse(obs.contains("Noise Gate"), "observed must be the FILTERED list, not the pre-typing recent list")
        }
        XCTAssertFalse(r.area.children.contains { $0.role == "AXMenu" },
                       "the popup must be dismissed on a miss — no modal menu left open")
    }

    /// (4) KEYSTONE REGRESSION — the popup is a SIBLING of the strips, NOT under the pressed slot.
    /// The old `selectPluginFromPopup` did `menuItems(under: slot)` and found nothing here (the slot
    /// has NO menu child); this proves the popup is located by walking the WINDOW tree instead. It
    /// FAILS against the old code path ("plugin ... not found").
    func testPopupIsSiblingOfStripsNotUnderSlot() async throws {
        let r = rig()
        let d = await daemon(r.p)
        _ = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Channel EQ")])
        XCTAssertFalse(r.slot.children.contains { $0.role == "AXMenu" },
                       "regression guard: the popup must NOT attach under the pressed slot")
        let strip = try await d.ax.find("vox")
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertTrue(groups.contains("Channel EQ"), "the sibling popup must be found and the plugin inserted")
    }

    /// (5) SETTLE-POLL through async AX lag: pressing the config leaf schedules the plugin group's
    /// appearance via scheduleChildAppend(afterReads:) so it stays invisible to pluginGroups for a
    /// couple of reads after the press. The tool's settlePlugins poll must wait it out. afterReads:2
    /// is the smallest non-tautological value (see StructureTools.settlePlugins / the note carried
    /// from the prior suite).
    func testInsertSettlesThroughAsyncLag() async throws {
        let r = rig(configLatency: 2)
        let d = await daemon(r.p)
        let res = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Compressor")])
        guard case .object(let o) = res else { return XCTFail() }
        XCTAssertEqual(o["plugin"], .string("Compressor"), "settlePlugins should poll until the async group-append lands")
    }

    /// (6) FALSE-NEGATIVE REGRESSION (real Logic, 2026-07-15, mcp_test.logicx): inserting a plugin
    /// makes Logic RE-RENDER the strip and invalidate the AXLayoutItem handle captured before the
    /// press. The old `settlePlugins(strip:)` polled that stale handle, read ZERO groups for the full
    /// timeout, and reported "plugin insert not confirmed" for an insert that ACTUALLY LANDED — a
    /// false negative that invites a duplicate-insert retry. The confirm must re-resolve the strip by
    /// NAME (a fresh mixer walk, like axdump) so it sees the new group. Here pressing "Stereo" REPLACES
    /// the strip node; the pre-insert handle stays empty, only a re-find sees "Compressor".
    func testInsertConfirmsAfterStripHandleGoesStale() async throws {
        let r = rig(staleStripOnInsert: true)
        let d = await daemon(r.p)
        let res = try await InsertPluginTool(daemon: d).invoke(["track": .string("vox"), "name": .string("Compressor")])
        guard case .object(let o) = res else { return XCTFail("insert should CONFIRM via a re-find, not false-negative") }
        XCTAssertEqual(o["plugin"], .string("Compressor"))
        let strip = try await d.ax.find("vox")   // fresh strip, found by name
        let groups = await d.ax.pluginGroups(strip).map(\.name)
        XCTAssertEqual(groups, ["Compressor"], "the re-found strip carries exactly the inserted group")
    }

    func testConfirmMatchesTruncatedThirdPartyName() {
        XCTAssertTrue(insertedNameMatches(group: "UAD AKG BX", requested: "UAD AKG BX 20"))
        XCTAssertTrue(insertedNameMatches(group: "SketchCass", requested: "SketchCassette II"))
        XCTAssertTrue(insertedNameMatches(group: "Compressor", requested: "Compressor"))
        XCTAssertFalse(insertedNameMatches(group: "RetroSyn", requested: "UAD AKG BX 20"))
        XCTAssertFalse(insertedNameMatches(group: "", requested: "Compressor"))
    }
}
