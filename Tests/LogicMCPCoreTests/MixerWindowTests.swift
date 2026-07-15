import XCTest
import MCP
@testable import LogicMCPCore

/// BUG 2 — the Mixer WINDOW must be open before any AX mixer read/write.
///
/// Ground truth (Fixtures/ax/strip_special.txt, real Logic 12.3): BOTH the Mixer window
/// ("Untitled 1 - Mixer: Tracks") and the arrange window ("Untitled 1 - Tracks") contain an
/// `AXLayoutArea description="Mixer"`. The arrange one is the Inspector's MINI-MIXER — the
/// selected track + its output, 2 strips. With the Mixer window closed, `mixerArea()` bound it
/// and `refresh_state` returned 2 strips REPORTING SUCCESS, silently REPLACING the shadow model
/// (proved live: the real track vanished from the model and every name-based tool then missed).
///
/// The fix has two halves, both exercised here:
///   (a) strict binding — only a mixer area inside a window titled "…Mixer…" (AXBridgeTests);
///   (b) SELF-HEAL — `Daemon.ensureMixerWindow()` presses `Window ▸ Open Mixer` (a plain menu
///       item, no dialog; `pressMenuPath` is background-safe and never steals focus) and
///       settle-polls for the window before any strip is addressed.
final class MixerWindowTests: XCTestCase {
    func daemon(_ p: FakeAXProvider) async -> Daemon { await Daemon(wire: InMemoryWire(), axProvider: p) }

    /// The fixture with the Mixer WINDOW closed (only the arrange window + its Inspector
    /// mini-mixer remain), plus a `Window` menu whose `Open Mixer` item re-opens it —
    /// ASYNCHRONOUSLY (`afterReads:`), because Logic's AX tree lags a menu press (~700ms
    /// observed), so a self-heal that trusts an immediate re-read would still see no window.
    func providerWithMixerClosed(openMixerWorks: Bool, appearsAfterReads: Int = 2)
        -> (p: FakeAXProvider, openMixerPresses: Counter) {
        let p = AXFixture.provider("strip_special")
        let mixerWindow = AXFixture.find([p.rootNode], title: "Untitled 1 - Mixer: Tracks")!
        p.rootNode.children.removeAll { $0 === mixerWindow }
        let presses = Counter()
        p.makeMenuBar([
            (bar: "Window", items: [(title: "Open Mixer", onPress: {
                presses.value += 1
                guard openMixerWorks else { return }   // models Logic ignoring the press
                p.rootNode.scheduleChildAppend(mixerWindow, afterReads: appearsAfterReads)
            })]),
        ])
        return (p, presses)
    }
    final class Counter { var value = 0 }

    /// THE regression test. Pre-fix, this returns the mini-mixer's 2 strips and reports success.
    func testRefreshStateOpensTheMixerWindowInsteadOfBindingTheMiniMixer() async throws {
        let (p, presses) = providerWithMixerClosed(openMixerWorks: true)
        let d = await daemon(p)
        let r = try await RefreshStateTool(daemon: d).invoke([:])
        guard case .object(let o) = r, case .array(let tracks)? = o["tracks"] else { return XCTFail() }
        XCTAssertEqual(tracks.count, 5, "must report the real mixer's 5 strips, not the mini-mixer's 2")
        XCTAssertEqual(presses.value, 1, "should have self-healed via Window ▸ Open Mixer exactly once")
        let names = await d.model.snapshot.tracks.map(\.name)
        XCTAssertEqual(names, ["Liverpool", "Inst 2", "Aux 1", "Stereo Out", "Master"])
    }

    /// If the window is already open, the self-heal must be a pure no-op — no menu press at all
    /// (a press that isn't needed is a press that can go wrong).
    func testMixerWindowAlreadyOpenPressesNothing() async throws {
        let p = AXFixture.provider("strip_special")
        let presses = Counter()
        p.makeMenuBar([(bar: "Window", items: [(title: "Open Mixer", onPress: { presses.value += 1 })])])
        let d = await daemon(p)
        _ = try await RefreshStateTool(daemon: d).invoke([:])
        XCTAssertEqual(presses.value, 0, "must not press Open Mixer when the Mixer window is already open")
    }

    /// Self-heal FAILS (Logic ignores the press) ⇒ a clean structured error. Never the 2-strip
    /// mini-mixer reported as success.
    func testRefreshStateThrowsWhenTheMixerWindowCannotBeOpened() async throws {
        let (p, presses) = providerWithMixerClosed(openMixerWorks: false)
        let d = await daemon(p)
        do {
            _ = try await RefreshStateTool(daemon: d).invoke([:])
            XCTFail("expected a ToolFailure, not a degraded 2-strip model")
        } catch let f as ToolFailure {
            XCTAssertEqual(f.layer, "ax")
            XCTAssertTrue(f.error.contains("mixer"), f.error)
        }
        XCTAssertEqual(presses.value, 1, "should have tried the self-heal before giving up")
        let names = await d.model.snapshot.tracks.map(\.name)
        XCTAssertTrue(names.isEmpty, "a failed refresh must not leave a mini-mixer model behind")
    }

    /// The self-heal must guard the STRIP-ADDRESSING tools too, not just refresh_state — the
    /// mini-mixer also contains a strip named "Liverpool" (it IS the selected track), so with the
    /// Mixer window closed, `set_mute` would find and press the INSPECTOR's mute switch. This
    /// asserts the press landed on the real Mixer window's strip.
    func testSetMuteSelfHealsAndAddressesTheRealMixerStrip() async throws {
        let (p, _) = providerWithMixerClosed(openMixerWorks: true)
        let d = await daemon(p)
        _ = try await SetMuteTool(daemon: d).invoke(["track": .string("Liverpool"), "on": .bool(true)])

        // By now the self-heal has re-opened the Mixer window, so both windows are in the tree.
        let mixerWindow = try XCTUnwrap(AXFixture.find([p.rootNode], title: "Untitled 1 - Mixer: Tracks"),
                                        "set_mute should have self-healed the Mixer window open")
        let arrange = try XCTUnwrap(AXFixture.find([p.rootNode], title: "Untitled 1 - Tracks"))
        let mixerLiverpool = try XCTUnwrap(AXFixture.find(mixerWindow.children, description: "Liverpool"))
        let inspectorLiverpool = try XCTUnwrap(AXFixture.find(arrange.children, description: "Liverpool"))
        XCTAssertEqual(AXFixture.find(mixerLiverpool.children, description: "mute")?.stringValue, "on")
        XCTAssertEqual(AXFixture.find(inspectorLiverpool.children, description: "mute")?.stringValue, "off",
                       "must not have pressed the Inspector mini-mixer's mute switch")
    }
}
