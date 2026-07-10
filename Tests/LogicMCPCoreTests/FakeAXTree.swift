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

    init(role: String, subrole: String? = nil, description: String? = nil,
         title: String? = nil, stringValue: String? = nil, value: Double? = nil,
         settable: Bool = false, children: [FakeAXNode] = [],
         minValue: Double? = nil, maxValue: Double? = nil) {
        self.role = role; self.subrole = subrole; self.description = description
        self.title = title; self.stringValue = stringValue; self.numberValue = value
        self.settable = settable; self.children = children
        self.minValue = minValue; self.maxValue = maxValue
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
        case .value: return n.stringValue ?? n.numberValue.map { String($0) }
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
            n.stringValue = (n.stringValue == "on") ? "off" : "on"
        case .increment: n.numberValue = (n.numberValue ?? 0) + 10
        case .decrement: n.numberValue = (n.numberValue ?? 0) - 10
        case .press: break
        }
    }
}
