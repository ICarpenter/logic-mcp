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
}
