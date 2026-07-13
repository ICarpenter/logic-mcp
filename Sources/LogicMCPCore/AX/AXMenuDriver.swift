import Foundation

/// Drives Logic's menus, popups, and dialogs by AXPress — the structural-ops actuator.
/// Behind the same `AXProvider` seam as `AXBridge`, so it is FakeAXTree-testable. Keys on
/// menu-item TITLE (stable, human-facing), never AXIdentifier. NEVER activates Logic.
public actor AXMenuDriver {
    private let p: AXProvider
    public init(provider: AXProvider) { self.p = provider }

    /// Descend the menu bar by title path and press the leaf. An `AXMenuBarItem`'s child is an
    /// `AXMenu` whose children are `AXMenuItem`s (some with nested `AXMenu` children).
    public func pressMenuPath(_ path: [String]) async throws {
        guard let bar = p.menuBar() else {
            throw ToolFailure(error: "no menu bar", layer: "ax",
                              expected: "Logic's menu bar", observed: "AXMenuBar unavailable")
        }
        var current = bar
        for (i, title) in path.enumerated() {
            let isLast = i == path.count - 1
            // Children of a bar/item are AXMenu(s); match the AXMenuItem/AXMenuBarItem by title.
            let candidates = menuItems(under: current)
            guard let match = candidates.first(where: {
                (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw ToolFailure(error: "menu item '\(title)' not found", layer: "ax",
                                  expected: "menu path \(path.joined(separator: " ▸ "))",
                                  observed: "available: \(candidates.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
            }
            if isLast {
                try p.perform(.press, on: match)
            } else {
                // Open the submenu so its items populate, then descend into it.
                try? p.perform(.press, on: match)
                try? await Task.sleep(for: .milliseconds(30))
                current = match
            }
        }
    }

    /// The AXMenuItems reachable one level under a bar item / menu item (through its AXMenu child).
    private func menuItems(under h: AXHandle) -> [AXHandle] {
        p.children(of: h).flatMap { child -> [AXHandle] in
            let role = p.string(.role, of: child)
            if role == "AXMenu" { return p.children(of: child) }
            if role == "AXMenuItem" || role == "AXMenuBarItem" { return [child] }
            return []
        }
    }

    /// Depth-first find by role and/or title (for dialogs/popups).
    public func descendant(of h: AXHandle, role: String? = nil, title: String? = nil) -> AXHandle? {
        func rec(_ x: AXHandle, _ d: Int) -> AXHandle? {
            if d > 12 { return nil }
            let rOK = role == nil || p.string(.role, of: x) == role
            let tOK = title == nil || (p.string(.title, of: x)?.caseInsensitiveCompare(title!) == .orderedSame)
            if (role != nil || title != nil), rOK, tOK { return x }
            for c in p.children(of: x) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.children(of: h).lazy.compactMap { rec($0, 0) }.first
    }

    /// The front-most sheet/dialog window (an AXSheet, or an AXWindow with a default button).
    public func frontSheet() -> AXHandle? {
        for w in p.windows() {
            if p.string(.subrole, of: w) == "AXDialog" || p.string(.subrole, of: w) == "AXSystemDialog" { return w }
            if descendant(of: w, role: "AXSheet", title: nil) != nil { return descendant(of: w, role: "AXSheet", title: nil) }
        }
        // Fallback: a top-level AXSheet.
        return p.windows().first { p.string(.role, of: $0) == "AXSheet" }
    }

    public func setField(in container: AXHandle, title: String, to value: String) throws {
        guard let field = descendant(of: container, role: "AXTextField", title: title)
            ?? descendant(of: container, role: "AXTextField", title: nil) else {
            throw ToolFailure(error: "no text field '\(title)' in dialog", layer: "ax",
                              expected: "a settable text field", observed: "none")
        }
        try p.setString(value, of: field)
    }

    public func pressButton(in container: AXHandle, title: String) throws {
        guard let btn = descendant(of: container, role: "AXButton", title: title) else {
            throw ToolFailure(error: "no '\(title)' button in dialog", layer: "ax",
                              expected: "a button titled '\(title)'", observed: "none")
        }
        try p.perform(.press, on: btn)
    }

    /// Press an arbitrary already-located element (used by later select_track/delete_track tools
    /// that find a strip/menu element via `descendant` and just need a plain AXPress).
    public func pressElement(_ h: AXHandle) throws { try p.perform(.press, on: h) }

    /// Open a popup on `control` (AXShowMenu, else AXPress), descend the item title `path`, press
    /// the leaf. On any miss, dismiss the popup (AXCancel) so nothing is left hanging.
    public func selectPopupItem(from control: AXHandle, path: [String]) async throws {
        do { try p.perform(.showMenu, on: control) } catch { try? p.perform(.press, on: control) }
        try? await Task.sleep(for: .milliseconds(40))
        var current = control
        for (i, title) in path.enumerated() {
            let items = menuItems(under: current)
            guard let match = items.first(where: {
                (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(title) == .orderedSame
            }) else {
                try? p.perform(.cancel, on: control)
                throw ToolFailure(error: "popup item '\(title)' not found", layer: "ax",
                                  expected: path.joined(separator: " ▸ "),
                                  observed: "available: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
            }
            if i == path.count - 1 { try p.perform(.press, on: match) }
            else { try? p.perform(.press, on: match); try? await Task.sleep(for: .milliseconds(30)); current = match }
        }
    }
}
