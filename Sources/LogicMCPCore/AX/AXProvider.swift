import Foundation

/// Opaque reference to one accessibility element. Boxes either a real `AXUIElement`
/// (held as `AnyObject` so this file needs no `ApplicationServices` import) or a fake
/// node identity. `@unchecked Sendable`: `AXUIElement` is a CF type that is not
/// formally Sendable, but every touch of it is confined to the `AXBridge` actor, so
/// crossing the provider boundary is safe in practice — same pattern as `CoreMIDIWire`.
public struct AXHandle: Hashable, @unchecked Sendable {
    let system: AnyObject?
    let fake: ObjectIdentifier?
    init(system: AnyObject) { self.system = system; self.fake = nil }
    init(fake: AnyObject) { self.system = nil; self.fake = ObjectIdentifier(fake) }
    public static func == (a: AXHandle, b: AXHandle) -> Bool {
        if let x = a.system, let y = b.system { return x === y }
        return a.fake == b.fake
    }
    public func hash(into h: inout Hasher) {
        if let s = system { h.combine(ObjectIdentifier(s)) } else { h.combine(fake) }
    }
}

public enum AXAttr: String {
    case role, subrole, description, title, value, help
}

public enum AXAction: String {
    case press = "AXPress", increment = "AXIncrement", decrement = "AXDecrement"
}

/// Thrown when Logic (or Accessibility permission) is unavailable.
public struct AXUnavailable: Error { public init() {} }

/// Narrow surface over the AX operations the mixer needs. `SystemAXProvider` wraps the
/// real C API; `FakeAXProvider` (test target) backs unit tests. Providers MUST NOT
/// activate Logic or set frontmost — the no-focus invariant.
public protocol AXProvider: Sendable {
    func root() throws -> AXHandle
    func windows() -> [AXHandle]
    func children(of h: AXHandle) -> [AXHandle]
    func string(_ attr: AXAttr, of h: AXHandle) -> String?
    func number(of h: AXHandle) -> Double?
    func isSettable(_ h: AXHandle) -> Bool
    func setNumber(_ v: Double, of h: AXHandle) throws
    func perform(_ action: AXAction, on h: AXHandle) throws
}
