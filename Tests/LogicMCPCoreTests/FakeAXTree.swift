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

    init(role: String, subrole: String? = nil, description: String? = nil,
         title: String? = nil, stringValue: String? = nil, value: Double? = nil,
         settable: Bool = false, children: [FakeAXNode] = []) {
        self.role = role; self.subrole = subrole; self.description = description
        self.title = title; self.stringValue = stringValue; self.numberValue = value
        self.settable = settable; self.children = children
    }
}

final class FakeAXProvider: AXProvider, @unchecked Sendable {
    let rootNode: FakeAXNode
    private var byHandle: [AXHandle: FakeAXNode] = [:]
    /// Set by a test to assert the no-focus invariant is never breached.
    private(set) var activateCount = 0

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
    func setNumber(_ v: Double, of h: AXHandle) throws {
        guard let n = node(h), n.settable else { throw AXUnavailable() }
        n.numberValue = v
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
