import Foundation
@testable import LogicMCPCore

/// One node in an in-memory AX tree that mirrors the roles/descriptions/values real
/// Logic exposes. `perform(.press)` on an AXSwitch flips its value off<->on, so tool
/// logic that "press only if the state differs, then re-read" is exercised faithfully.
final class FakeAXNode {
    let role: String
    let subrole: String?
    let description: String?
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
    /// Test-only window-open/close wiring: set on an "open" button so a press adds this window
    /// to the tree (simulating Logic opening a plugin), or on a "close" button so a press
    /// removes it. Both nil (the default) preserves the old no-op press behavior for every
    /// other test — only tests that model a slot's window appearing/disappearing set these.
    var opensWindow: FakeAXNode?
    var closesWindow: FakeAXNode?

    init(role: String, subrole: String? = nil, description: String? = nil,
         title: String? = nil, stringValue: String? = nil, value: Double? = nil,
         settable: Bool = false, children: [FakeAXNode] = [],
         minValue: Double? = nil, maxValue: Double? = nil, pressLatency: Int = 0) {
        self.role = role; self.subrole = subrole; self.description = description
        self.title = title; self.stringValue = stringValue; self.numberValue = value
        self.settable = settable; self.children = children
        self.minValue = minValue; self.maxValue = maxValue
        self.pressLatency = pressLatency
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
    func windows() -> [AXHandle] {
        rootNode.children.filter { $0.role == "AXWindow" }.map { AXHandle(fake: $0) }
    }
    func children(of h: AXHandle) -> [AXHandle] {
        (node(h)?.children ?? []).map { AXHandle(fake: $0) }
    }
    func string(_ attr: AXAttr, of h: AXHandle) -> String? {
        guard let n = node(h) else { return nil }
        switch attr {
        case .role: return n.role
        case .subrole: return n.subrole
        case .description: return n.description
        case .title: return n.title
        case .help: return nil
        case .value: return n.readValueForLatency() ?? n.numberValue.map { String($0) }
        }
    }
    func number(of h: AXHandle) -> Double? { node(h)?.numberValue }
    func isSettable(_ h: AXHandle) -> Bool { node(h)?.settable ?? false }
    func minMax(of h: AXHandle) -> (Double?, Double?) {
        guard let n = node(h) else { return (nil, nil) }
        return (n.minValue, n.maxValue)
    }
    func setNumber(_ v: Double, of h: AXHandle) throws {
        guard let n = node(h), n.settable else { throw AXUnavailable() }
        let cur = n.numberValue ?? 0
        if nudgeMode {
            if v > cur { n.numberValue = cur + 1 } else if v < cur { n.numberValue = cur - 1 }
        } else {
            n.numberValue = v
        }
        onSetNumber?(n, n.numberValue ?? cur)   // hook sees the RESULTING value (Task 6 titles)
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
        }
    }
}
