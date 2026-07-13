import ApplicationServices
import Cocoa

/// Real `AXUIElement`-backed provider. Read-only except `perform`/`setNumber`. Never
/// activates Logic (no `AXFrontmost`, no `NSRunningApplication.activate`).
///
/// `app` is optional and `init` never throws for a missing Logic process or missing
/// Accessibility permission — it just stores `nil`. This lets `Serve` always construct a
/// `SystemAXProvider` at startup; AX tools then fail gracefully with a structured
/// `ToolFailure(layer: "ax")` at call time (via `root()`/`windows()`) instead of the daemon
/// aborting when Logic isn't running yet or permission hasn't been granted.
public final class SystemAXProvider: AXProvider, @unchecked Sendable {
    private let app: AXUIElement?
    public init(bundlePrefix: String = "com.apple.logic") throws {
        guard AXIsProcessTrusted(),
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier?.hasPrefix(bundlePrefix) == true
              }) else {
            self.app = nil
            return
        }
        self.app = AXUIElementCreateApplication(running.processIdentifier)
    }

    private func raw(_ h: AXHandle) -> AXUIElement { h.system as! AXUIElement }

    public func root() throws -> AXHandle {
        guard let app else { throw AXUnavailable() }
        return AXHandle(system: app)
    }

    public func windows() -> [AXHandle] {
        guard let app else { return [] }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.map { AXHandle(system: $0) }
    }
    public func menuBar() -> AXHandle? {
        guard let app else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &v) == .success,
              let mb = v else { return nil }
        return AXHandle(system: mb as! AXUIElement)
    }
    public func children(of h: AXHandle) -> [AXHandle] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.map { AXHandle(system: $0) }
    }
    public func string(_ attr: AXAttr, of h: AXHandle) -> String? {
        let key: String = switch attr {
        case .role: kAXRoleAttribute as String
        case .subrole: kAXSubroleAttribute as String
        case .description: kAXDescriptionAttribute as String
        case .title: kAXTitleAttribute as String
        case .value: kAXValueAttribute as String
        case .help: kAXHelpAttribute as String
        }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), key as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    public func number(of h: AXHandle) -> Double? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw(h), kAXValueAttribute as CFString, &v) == .success,
              let n = v as? NSNumber else { return nil }
        return n.doubleValue
    }
    public func isSettable(_ h: AXHandle) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(raw(h), kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }
    public func setNumber(_ v: Double, of h: AXHandle) throws {
        let r = AXUIElementSetAttributeValue(raw(h), kAXValueAttribute as CFString, v as CFNumber)
        if r != .success { throw AXUnavailable() }
    }
    public func perform(_ action: AXAction, on h: AXHandle) throws {
        let r = AXUIElementPerformAction(raw(h), action.rawValue as CFString)
        if r != .success { throw AXUnavailable() }
    }
    public func minMax(of h: AXHandle) -> (Double?, Double?) {
        func d(_ key: String) -> Double? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(raw(h), key as CFString, &v) == .success,
                  let n = v as? NSNumber else { return nil }
            return n.doubleValue
        }
        return (d(kAXMinValueAttribute as String), d(kAXMaxValueAttribute as String))
    }
}
