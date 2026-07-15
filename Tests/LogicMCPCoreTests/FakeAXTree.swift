import Foundation
@testable import LogicMCPCore

/// One node in an in-memory AX tree that mirrors the roles/descriptions/values real
/// Logic exposes. `perform(.press)` on an AXSwitch flips its value off<->on, so tool
/// logic that "press only if the state differs, then re-read" is exercised faithfully.
final class FakeAXNode {
    let role: String
    let subrole: String?
    /// `var`, not `let`: a routing-popup leaf's `onPress` (Task 7's `set_output`) needs to
    /// mutate the output BUTTON's own description in place — that's how the fake models Logic
    /// updating the button's displayed destination after a popup selection lands.
    var description: String?
    var title: String?
    var stringValue: String?
    var numberValue: Double?
    let settable: Bool
    var children: [FakeAXNode]
    let minValue: Double?
    let maxValue: Double?
    /// Models Logic's ASYNCHRONOUS AXSwitch value update: the number of `.value` string reads
    /// that must occur AFTER a press before the flipped value becomes visible. When a press
    /// lands on a node with `pressLatency > 0`, the flip is held in `pendingStringValue` and
    /// this countdown decrements on each `.value` read; the new value is only returned once it
    /// hits 0. Zero (the default) is synchronous — a press's new value is visible immediately,
    /// unchanged from prior behavior.
    var pressLatency = 0
    private var pendingStringValue: String?
    private var latencyCountdown = 0
    /// Models Logic's ASYNCHRONOUS AXUIElementSetAttributeValue update on a numeric slider: the
    /// number of `number(of:)` reads that must occur AFTER a `setNumber` call before the nudged
    /// value becomes visible. Mirrors `pressLatency`/`pendingStringValue` above exactly, just for
    /// the numeric `.value` attribute instead of the AXSwitch string `.value`. Zero (the default)
    /// is synchronous — a setNumber's new value is visible immediately, unchanged prior behavior.
    var setValueLatency = 0
    private var pendingNumberValue: Double?
    private var numberLatencyCountdown = 0
    /// Models Logic's ASYNCHRONOUS AX-tree description update after a routing-popup leaf press
    /// (e.g. `set_output`'s output button showing the new destination): a description change
    /// scheduled via `scheduleDescriptionChange(to:afterReads:)` is held back from `description`
    /// until this many subsequent `.description` reads on THIS node have occurred — same
    /// countdown shape as `pendingChildAppend`/`childAppendCountdown` above, just keyed to the
    /// `.description` string attribute instead of a `children(of:)` structural read.
    private var pendingDescription: String?
    private var descriptionCountdown = 0
    /// Test-only window-open/close wiring: set on an "open" button so a press adds this window
    /// to the tree (simulating Logic opening a plugin), or on a "close" button so a press
    /// removes it. Both nil (the default) preserves the old no-op press behavior for every
    /// other test — only tests that model a slot's window appearing/disappearing set these.
    var opensWindow: FakeAXNode?
    var closesWindow: FakeAXNode?
    /// Test-only hook fired on `.press` (after any AXSwitch flip / window open-close behavior)
    /// so a pressed menu item can mutate the fake tree — e.g. "New Audio Track adds a strip".
    var onPress: (() -> Void)?
    /// Test-only hook fired on `.cancel` (AXCancel) so a test can model a popup being DISMISSED —
    /// e.g. the plugin-insert popup removing itself from the mixer area when the driver bails on a
    /// miss. Nil (the default) makes `.cancel` a no-op, unchanged from prior behavior.
    var onCancel: (() -> Void)?
    /// Test-only search-FILTER hook. When set on a node, the provider's `children(of:)` returns
    /// THIS closure's result instead of the static `children`/latency list — so a popup AXMenu can
    /// return a DIFFERENT set of menu items depending on the search field's current value. This is
    /// what models Logic's live insert-search filter: `setString(query, of: searchField)` changes
    /// which AXMenuItems the popup subsequently yields. Nil (the default) preserves the static
    /// children read for every other node/test.
    var dynamicChildren: (() -> [FakeAXNode])?
    /// Test-only record of every `setString` value written to THIS node, in call order. Lets a
    /// test assert (independent oracle) that the driver actually TYPED into the search field —
    /// `["Compressor"]` proves the query was set, not merely that some static value matched.
    private(set) var setStringLog: [String] = []
    func recordSetString(_ s: String) { setStringLog.append(s); stringValue = s }
    /// Models Logic's ASYNCHRONOUS AX-tree structural update after a menu press (e.g. a new
    /// mixer strip appearing): a child scheduled via `scheduleChildAppend(_:afterReads:)` is
    /// held back from `children` until this many subsequent `children(of:)` reads on THIS node
    /// have occurred — same countdown shape as `pressLatency`/`setValueLatency` above, just keyed
    /// to a structural read instead of a value attribute read.
    private var pendingChildAppend: FakeAXNode?
    private var childAppendCountdown = 0

    init(role: String, subrole: String? = nil, description: String? = nil,
         title: String? = nil, stringValue: String? = nil, value: Double? = nil,
         settable: Bool = false, children: [FakeAXNode] = [],
         minValue: Double? = nil, maxValue: Double? = nil, pressLatency: Int = 0,
         setValueLatency: Int = 0) {
        self.role = role; self.subrole = subrole; self.description = description
        self.title = title; self.stringValue = stringValue; self.numberValue = value
        self.settable = settable; self.children = children
        self.minValue = minValue; self.maxValue = maxValue
        self.pressLatency = pressLatency
        self.setValueLatency = setValueLatency
    }

    /// Called by the provider's `.value` string read. If a press is pending latency, decrements
    /// the countdown and only reveals the flipped value once it reaches 0.
    func readValueForLatency() -> String? {
        guard let pending = pendingStringValue else { return stringValue }
        if latencyCountdown > 0 {
            latencyCountdown -= 1
            return stringValue   // still stale
        }
        stringValue = pending
        pendingStringValue = nil
        return stringValue
    }

    /// Called by the provider's `.press` action on an AXSwitch. Computes the flipped value and,
    /// if `pressLatency > 0`, holds it pending instead of publishing it immediately.
    func flipSwitchValue() {
        let flipped = (stringValue == "on") ? "off" : "on"
        if pressLatency > 0 {
            pendingStringValue = flipped
            latencyCountdown = pressLatency
        } else {
            stringValue = flipped
        }
    }

    /// Called by the provider's `number(of:)` read. If a setNumber left a value pending latency,
    /// decrements the countdown and only reveals the new value once it reaches 0 — same shape as
    /// `readValueForLatency()` above.
    func readNumberForLatency() -> Double? {
        guard let pending = pendingNumberValue else { return numberValue }
        if numberLatencyCountdown > 0 {
            numberLatencyCountdown -= 1
            return numberValue   // still stale
        }
        numberValue = pending
        pendingNumberValue = nil
        return numberValue
    }

    /// Called by the provider's `setNumber`. Publishes `new` immediately if `setValueLatency == 0`;
    /// otherwise holds it pending so `number(of:)` keeps returning the pre-write value for
    /// `setValueLatency` reads (see `readNumberForLatency()`) — models Logic's asynchronous
    /// slider-value read-back while the fake's own nudge math (which reads `numberValue`
    /// directly, like `flipSwitchValue` reads `stringValue` directly) still sees a consistent
    /// value once each write's pending reveal has drained.
    func scheduleNumberValue(_ new: Double) {
        if setValueLatency > 0 {
            pendingNumberValue = new
            numberLatencyCountdown = setValueLatency
        } else {
            numberValue = new
        }
    }

    /// Schedule `child` to be appended to `children`, but only revealed after `afterReads`
    /// subsequent `children(of:)` reads on this node (see `readChildrenForLatency()`). Zero
    /// appends immediately — the old synchronous "onPress mutates .children directly" shape
    /// every other structural-ops test still uses.
    func scheduleChildAppend(_ child: FakeAXNode, afterReads: Int) {
        if afterReads <= 0 {
            children.append(child)
        } else {
            pendingChildAppend = child
            childAppendCountdown = afterReads
        }
    }

    /// Called by the provider's `children(of:)` on this node. If an append is pending latency,
    /// decrements the countdown and keeps returning the stale (pre-append) list; the pending
    /// child is appended and revealed only once the countdown reaches 0 — same shape as
    /// `readValueForLatency()`/`readNumberForLatency()` above, applied to a structural read.
    func readChildrenForLatency() -> [FakeAXNode] {
        guard let pending = pendingChildAppend else { return children }
        if childAppendCountdown > 0 {
            childAppendCountdown -= 1
            return children   // still stale — pending strip not yet visible
        }
        children.append(pending)
        pendingChildAppend = nil
        return children
    }

    /// Schedule `description` to change to `new`, but only revealed after `afterReads` subsequent
    /// `.description` reads on this node (see `readDescriptionForLatency()`). Zero (or omitted)
    /// changes immediately — the old synchronous "onPress mutates .description directly" shape
    /// every other `set_output` test still uses (see the class-doc comment on `description` above).
    func scheduleDescriptionChange(to new: String, afterReads: Int) {
        if afterReads <= 0 {
            description = new
        } else {
            pendingDescription = new
            descriptionCountdown = afterReads
        }
    }

    /// Called by the provider's `.description` string read. If a change is pending latency,
    /// decrements the countdown and keeps returning the stale (pre-change) description; the
    /// pending value is published and revealed only once the countdown reaches 0 — same shape as
    /// `readValueForLatency()`/`readChildrenForLatency()` above, applied to `.description`.
    func readDescriptionForLatency() -> String? {
        guard let pending = pendingDescription else { return description }
        if descriptionCountdown > 0 {
            descriptionCountdown -= 1
            return description   // still stale
        }
        description = pending
        pendingDescription = nil
        return description
    }
}

final class FakeAXProvider: AXProvider, @unchecked Sendable {
    let rootNode: FakeAXNode
    private var byHandle: [AXHandle: FakeAXNode] = [:]
    /// Set by a test to assert the no-focus invariant is never breached.
    private(set) var activateCount = 0
    /// When true, setNumber moves ±1 toward the target (models real Logic sliders); when
    /// false it sets absolutely. Default false so Task 1's tests are unchanged.
    var nudgeMode = false
    /// Hook that sees the RESULTING value after each setNumber call (Task 6 titles).
    var onSetNumber: ((FakeAXNode, Double) -> Void)?
    /// Root of the fake `AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem` tree, set directly by
    /// a test or via `makeMenuBar(_:)` below. Nil (the default) makes `menuBar()` return nil,
    /// same "unavailable" shape as `SystemAXProvider` with no running Logic. `didSet` indexes the
    /// tree into `byHandle` — it lives outside `rootNode`'s children, so it wouldn't otherwise be
    /// reachable by `node(_:)`.
    var menuBarNode: FakeAXNode? {
        didSet { if let bar = menuBarNode { index(bar) } }
    }

    init(root: FakeAXNode) {
        self.rootNode = root
        index(root)
    }
    private func index(_ n: FakeAXNode) {
        byHandle[AXHandle(fake: n)] = n
        n.children.forEach(index)
    }
    private func node(_ h: AXHandle) -> FakeAXNode? { byHandle[h] }

    func root() throws -> AXHandle { AXHandle(fake: rootNode) }
    /// Goes through `readChildrenForLatency()` (like `children(of:)`) so a test can model Logic
    /// opening a WINDOW asynchronously after a menu press — `Window ▸ Open Mixer` schedules the
    /// Mixer window via `scheduleChildAppend(_:afterReads:)` and it stays invisible to `windows()`
    /// for that many reads. With nothing pending this is exactly the old
    /// `rootNode.children.filter` — unchanged behavior for every other test.
    func windows() -> [AXHandle] {
        let kids = rootNode.readChildrenForLatency()
        for k in kids where byHandle[AXHandle(fake: k)] == nil { index(k) }
        return kids.filter { $0.role == "AXWindow" }.map { AXHandle(fake: $0) }
    }
    func children(of h: AXHandle) -> [AXHandle] {
        // A node with a `dynamicChildren` filter (a search-popup AXMenu) computes its children
        // fresh each read from the current search-field value — models Logic's live insert filter.
        // Every other node keeps the static/latency read path unchanged.
        let kids = node(h)?.dynamicChildren?() ?? node(h)?.readChildrenForLatency() ?? []
        // Self-healing index: a node appended to the tree after construction (e.g. by an
        // `onPress` hook mutating `.children` directly, as structural-ops tests do to model
        // "New Audio Track adds a strip") isn't in `byHandle` yet — index it (and its
        // descendants) lazily on first traversal, same as the explicit `index(opens)` call
        // in the `opensWindow` press case, just generalized to any tree mutation.
        for k in kids where byHandle[AXHandle(fake: k)] == nil { index(k) }
        return kids.map { AXHandle(fake: $0) }
    }
    func string(_ attr: AXAttr, of h: AXHandle) -> String? {
        guard let n = node(h) else { return nil }
        switch attr {
        case .role: return n.role
        case .subrole: return n.subrole
        case .description: return n.readDescriptionForLatency()
        case .title: return n.title
        case .help: return nil
        case .value: return n.readValueForLatency() ?? n.numberValue.map { String($0) }
        }
    }
    func number(of h: AXHandle) -> Double? { node(h)?.readNumberForLatency() }
    func isSettable(_ h: AXHandle) -> Bool { node(h)?.settable ?? false }
    func minMax(of h: AXHandle) -> (Double?, Double?) {
        guard let n = node(h) else { return (nil, nil) }
        return (n.minValue, n.maxValue)
    }
    func menuBar() -> AXHandle? { menuBarNode.map { AXHandle(fake: $0) } }
    func setString(_ s: String, of h: AXHandle) throws {
        guard let n = node(h) else { throw AXUnavailable() }
        n.recordSetString(s)   // sets stringValue AND records the call for the type-then-select oracle
    }
    func setNumber(_ v: Double, of h: AXHandle) throws {
        guard let n = node(h), n.settable else { throw AXUnavailable() }
        let cur = n.numberValue ?? 0
        let new: Double
        if nudgeMode {
            if v > cur { new = cur + 1 } else if v < cur { new = cur - 1 } else { new = cur }
        } else {
            new = v
        }
        n.scheduleNumberValue(new)
        onSetNumber?(n, new)   // hook sees the RESULTING value (Task 6 titles)
    }
    func perform(_ action: AXAction, on h: AXHandle) throws {
        guard let n = node(h) else { throw AXUnavailable() }
        switch action {
        case .press where n.subrole == "AXSwitch":
            n.flipSwitchValue()
        case .increment: n.numberValue = (n.numberValue ?? 0) + 10
        case .decrement: n.numberValue = (n.numberValue ?? 0) - 10
        case .press:
            // Simulate a plugin window opening/closing (Bug 2 regression coverage). Both are
            // nil in every other test, so this is a no-op there — unchanged prior behavior.
            if let opens = n.opensWindow, !rootNode.children.contains(where: { $0 === opens }) {
                rootNode.children.append(opens)
                index(opens)
            }
            if let closes = n.closesWindow {
                rootNode.children.removeAll { $0 === closes }
            }
        case .showMenu:
            break   // no-op in the fake; callers use it to request a popup (Task 3+)
        case .cancel:
            n.onCancel?()   // lets a test model a popup DISMISSING itself on the driver's bail-out
        }
        if action == .press { n.onPress?() }
    }

    /// Builds `AXMenuBar → AXMenuBarItem(title) → AXMenu → AXMenuItem(title, onPress:)` and
    /// installs it as `menuBarNode`, in `items` order (a dictionary would make "available: ..."
    /// error-message assertions order-flaky). Convenience for structural-ops tests so they don't
    /// hand-build the tree the way `AXMenuDriverTests.providerPressingSetsFlag` does.
    func makeMenuBar(_ items: [(bar: String, items: [(title: String, onPress: (() -> Void)?)])]) {
        let barItems = items.map { spec -> FakeAXNode in
            let menuItems = spec.items.map { leaf -> FakeAXNode in
                let item = FakeAXNode(role: "AXMenuItem", title: leaf.title)
                item.onPress = leaf.onPress
                return item
            }
            let menu = FakeAXNode(role: "AXMenu", children: menuItems)
            return FakeAXNode(role: "AXMenuBarItem", title: spec.bar, children: [menu])
        }
        menuBarNode = FakeAXNode(role: "AXMenuBar", children: barItems)
    }
}
