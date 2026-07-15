import XCTest
@testable import LogicMCPCore

final class AXMenuDriverTests: XCTestCase {
    /// A menu bar with Track → New Audio Track (whose press sets a flag).
    func providerPressingSetsFlag(_ flag: Flag) -> FakeAXProvider {
        let item = FakeAXNode(role: "AXMenuItem", title: "New Audio Track")
        item.onPress = { flag.value = true }
        let menu = FakeAXNode(role: "AXMenu", children: [item])
        let track = FakeAXNode(role: "AXMenuBarItem", title: "Track", children: [menu])
        let bar = FakeAXNode(role: "AXMenuBar", children: [track])
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication"))
        p.menuBarNode = bar
        return p
    }
    final class Flag { var value = false }

    func testPressMenuPathPressesLeafItem() async throws {
        let flag = Flag()
        let driver = AXMenuDriver(provider: providerPressingSetsFlag(flag))
        try await driver.pressMenuPath(["Track", "New Audio Track"])
        XCTAssertTrue(flag.value)
    }

    func testPressMenuPathUnknownItemThrows() async throws {
        let driver = AXMenuDriver(provider: providerPressingSetsFlag(Flag()))
        do { try await driver.pressMenuPath(["Track", "Nope"]); XCTFail("expected throw") }
        catch let f as ToolFailure { XCTAssertEqual(f.layer, "ax") }
    }

    // MARK: - BUG 3: opt-in PREFIX matching for the retitled Undo/Redo items
    //
    // Logic retitles Edit ▸ Undo per operation ("Undo Create Track"). `pressMenuItemWithPrefix`
    // matches a prefix and returns the FULL title; `pressMenuPath` MUST stay an exact match, or
    // every other menu path becomes ambiguous.

    /// An Edit menu with the given item titles, recording which one gets pressed.
    func editMenuProvider(_ titles: [String], pressed: Pressed) -> FakeAXProvider {
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication"))
        p.makeMenuBar([(bar: "Edit", items: titles.map { title in
            (title: title, onPress: { pressed.title = title })
        })])
        return p
    }
    final class Pressed { var title: String? }

    func testPressMenuItemWithPrefixMatchesRetitledItemAndReturnsFullTitle() async throws {
        let pressed = Pressed()
        let driver = AXMenuDriver(provider: editMenuProvider(["Undo Create Track", "Redo"], pressed: pressed))
        let title = try await driver.pressMenuItemWithPrefix(menu: "Edit", prefix: "Undo")
        XCTAssertEqual(title, "Undo Create Track")
        XCTAssertEqual(pressed.title, "Undo Create Track")
    }

    /// A bare "Undo" (fresh project, nothing to name) must still match.
    func testPressMenuItemWithPrefixMatchesTheBareTitle() async throws {
        let pressed = Pressed()
        let driver = AXMenuDriver(provider: editMenuProvider(["Undo", "Redo"], pressed: pressed))
        let title = try await driver.pressMenuItemWithPrefix(menu: "Edit", prefix: "Undo")
        XCTAssertEqual(title, "Undo")
    }

    /// Ellipsis items are DIALOGS ("Undo History…" opens a window) — never the undo action.
    func testPressMenuItemWithPrefixSkipsEllipsisDialogItems() async throws {
        let pressed = Pressed()
        let driver = AXMenuDriver(provider: editMenuProvider(["Undo History…", "Undo Delete Tracks"],
                                                             pressed: pressed))
        let title = try await driver.pressMenuItemWithPrefix(menu: "Edit", prefix: "Undo")
        XCTAssertEqual(title, "Undo Delete Tracks")
        XCTAssertEqual(pressed.title, "Undo Delete Tracks", "must not press the dialog item")
    }

    /// The prefix must end on a word boundary: "Undo" matches "Undo X", never "Undoable X".
    func testPressMenuItemWithPrefixRequiresAWordBoundary() async throws {
        let driver = AXMenuDriver(provider: editMenuProvider(["Undoable Thing"], pressed: Pressed()))
        do {
            _ = try await driver.pressMenuItemWithPrefix(menu: "Edit", prefix: "Undo")
            XCTFail("expected throw")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("no 'Undo' item"), f.error)
        }
    }

    /// Redo gets the same treatment for free — it is retitled identically ("Redo Create Track").
    func testPressMenuItemWithPrefixWorksForRedo() async throws {
        let pressed = Pressed()
        let driver = AXMenuDriver(provider: editMenuProvider(["Undo Create Track", "Redo Create Track"],
                                                             pressed: pressed))
        let title = try await driver.pressMenuItemWithPrefix(menu: "Edit", prefix: "Redo")
        XCTAssertEqual(title, "Redo Create Track")
    }

    /// GUARD: the prefix match must NOT have leaked into `pressMenuPath`. "New Audio Track" must
    /// hit exactly that item, never "New Audio Track With Duplicate Settings" (listed first here,
    /// so a prefix-matching pressMenuPath would take the wrong one).
    func testPressMenuPathStaysAnExactMatch() async throws {
        let pressed = Pressed()
        let p = FakeAXProvider(root: FakeAXNode(role: "AXApplication"))
        p.makeMenuBar([(bar: "Track", items: [
            (title: "New Audio Track With Duplicate Settings", onPress: { pressed.title = "wrong" }),
            (title: "New Audio Track", onPress: { pressed.title = "right" }),
        ])])
        try await AXMenuDriver(provider: p).pressMenuPath(["Track", "New Audio Track"])
        XCTAssertEqual(pressed.title, "right", "pressMenuPath must still match by EQUALITY")
    }
}
