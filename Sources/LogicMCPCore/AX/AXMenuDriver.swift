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

    /// Press the item under menu-bar item `menu` whose title starts with `prefix`, and return the
    /// FULL title actually pressed.
    ///
    /// BUG 3 (real Logic): Logic RETITLES the Edit menu's undo item per operation — "Undo Create
    /// Track", "Undo Delete Tracks", "Redo Create Track". `pressMenuPath(["Edit", "Undo"])` matches
    /// by EQUALITY, so it worked exactly once (on a fresh project, where the item really is titled
    /// "Undo") and then failed forever with `menu item 'Undo' not found`.
    ///
    /// This is deliberately an OPT-IN sibling of `pressMenuPath`, not a loosening of it: a global
    /// prefix match would make every other path ambiguous ("New Audio Track" would also match "New
    /// Audio Track With Duplicate Settings"). Only undo/redo need it, and they get it here.
    ///
    /// Two guards keep the match honest:
    ///   * the title must be EXACTLY `prefix` or start with `prefix + " "` — so "Undo" never
    ///     matches an unrelated "Undoable…"-style item;
    ///   * items ending in an ellipsis are SKIPPED — Logic's Edit menu also carries a DIALOG item
    ///     ("Undo History…"), and pressing that opens a window instead of undoing anything.
    /// The first item in MENU ORDER that survives both wins (Logic's live undo item is first).
    ///
    /// Returns the full title so the caller can report what Logic actually reverted — that string
    /// is our independent oracle (never trust the press's return code).
    public func pressMenuItemWithPrefix(menu: String, prefix: String) async throws -> String {
        guard let bar = p.menuBar() else {
            throw ToolFailure(error: "no menu bar", layer: "ax",
                              expected: "Logic's menu bar", observed: "AXMenuBar unavailable")
        }
        guard let barItem = menuItems(under: bar).first(where: {
            (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(menu) == .orderedSame
        }) else {
            throw ToolFailure(error: "menu '\(menu)' not found", layer: "ax",
                              expected: "the \(menu) menu", observed: "available: \(menuItems(under: bar).compactMap { p.string(.title, of: $0) }.joined(separator: ", "))")
        }
        try? p.perform(.press, on: barItem)              // open it so its items populate
        try? await Task.sleep(for: .milliseconds(30))
        let items = menuItems(under: barItem)
        let match = items.first { h in
            guard let t = p.string(.title, of: h) else { return false }
            guard t == prefix || t.hasPrefix(prefix + " ") else { return false }
            return !t.hasSuffix("…") && !t.hasSuffix("...")   // skip dialog items ("Undo History…")
        }
        guard let match, let title = p.string(.title, of: match) else {
            throw ToolFailure(error: "no '\(prefix)' item in the \(menu) menu", layer: "ax",
                              expected: "an item titled '\(prefix)' or '\(prefix) …' (Logic retitles it per operation)",
                              observed: "available: \(items.compactMap { p.string(.title, of: $0) }.filter { !$0.isEmpty }.joined(separator: ", "))")
        }
        try p.perform(.press, on: match)
        return title
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

    /// Press an arbitrary already-located element via a plain AXPress. Retained as a low-level
    /// primitive (no current tool presses a strip — AX cannot change Logic's track selection, so
    /// select_track was removed and delete_track is disabled; see Fixtures/ax/selection.txt).
    public func pressElement(_ h: AXHandle) throws { try p.perform(.press, on: h) }

    /// Set a routing destination via the output button's SEARCH-driven popup — the SAME mechanism as
    /// `selectPluginFromPopup`. Real Logic (2026-07-15, outputprobe): the routing popup attaches as a
    /// SIBLING of the mixer strips (NOT under the button — `menuItems(under: control)` finds nothing),
    /// and its first item is an `AXTextField subrole="AXSearchField"`. `setString(dest)` triggers
    /// Logic's filter with NO keystrokes/CGEvents, FLATTENING the nested "Bus ▸"/"Output ▸" submenus
    /// into a top-level match list; press the EXACT case-insensitive title match — NOT the first
    /// result ("Bus 3" also surfaces "Bus 30"/"Bus 13"/… — see Fixtures/ax/popup_output.txt). The
    /// TOOL settle-polls the strip's output slot afterwards as the independent oracle. Dismisses the
    /// popup (AXCancel on the control) on ANY throw path so no modal menu lingers.
    public func selectRoutingDestination(from control: AXHandle, dest: String) async throws {
        try? p.perform(.press, on: control)     // opens the popup (return code unreliable — read the tree)
        guard let popup = await settleForSearchPopup() else {
            throw ToolFailure(error: "routing popup did not open", layer: "ax",
                              expected: "a routing popup carrying a search field (AXSearchField)",
                              observed: "pressed the output button but no AXMenu with a search field appeared within 2s")
        }
        do { try p.setString(dest, of: popup.search) }
        catch {
            try? p.perform(.cancel, on: control)
            throw ToolFailure(error: "could not type into the routing search field", layer: "ax",
                              expected: "a settable AXSearchField", observed: "\(error)")
        }
        var seen: [String] = []
        var match: AXHandle?
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            let items = searchPopupItems(in: popup.menu)
            seen = items.compactMap { p.string(.title, of: $0) }
            match = items.first { (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(dest) == .orderedSame }
            if match != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        guard let hit = match else {
            try? p.perform(.cancel, on: control)
            throw ToolFailure(error: "no routing destination '\(dest)'", layer: "ax",
                              expected: "an exact match for '\(dest)' after filtering the routing search",
                              observed: "filtered results: \(seen.prefix(30).joined(separator: ", "))")
        }
        try p.perform(.press, on: hit)
    }

    /// Select `choice` in an in-table enum AXPopUpButton by pressing it and walking its plain AXMenu.
    /// Distinct from the SEARCH-driven catalog popups (selectRoutingDestination/selectPluginFromPopup):
    /// an in-table enum is a small fixed list that opens a plain AXMenu of AXMenuItems (Task 0). Prefers
    /// an EXACT case-insensitive title match, falling back to tolerant prefix matching only when no exact
    /// match exists (for abbreviated item titles, e.g. item "18" vs display "18 dB/Oct"). Dismisses the
    /// popup (AXCancel) on any throw path — including a failed final press. The TOOL re-reads the popup's
    /// value afterwards as the independent oracle.
    public func selectEnumChoice(from popup: AXHandle, choice: String) async throws {
        let priorValue = p.string(.value, of: popup)      // captured BEFORE opening — the settle-poll's baseline
        try? p.perform(.press, on: popup)                 // open it (return code unreliable — read the tree)
        // The AXMenu populates ASYNCHRONOUSLY after the press (~100ms live, not the old fixed 40ms which
        // read an empty menu when Logic was busy) — settle-poll until items appear or a deadline.
        var items = menuItems(under: popup)
        let itemsDeadline = ContinuousClock.now + .milliseconds(1000)
        while items.isEmpty && ContinuousClock.now < itemsDeadline {
            try? await Task.sleep(for: .milliseconds(50))
            items = menuItems(under: popup)
        }
        let c = choice.lowercased()
        func title(_ h: AXHandle) -> String { (p.string(.title, of: h) ?? "").lowercased() }
        // Prefer an EXACT match; only fall back to tolerant prefix matching (for abbreviated item
        // titles, e.g. item "18" vs display "18 dB/Oct") when no exact title matches — otherwise a
        // space-prefixed sibling ("Opto Fast" for choice "Opto") would be wrongly selected.
        let hitOpt = items.first { title($0) == c }
            ?? items.first { let t = title($0); return !t.isEmpty && (c.hasPrefix(t + " ") || t.hasPrefix(c + " ")) }
        guard let hit = hitOpt else {
            try? p.perform(.cancel, on: popup)
            throw ToolFailure(error: "no choice '\(choice)'", layer: "ax",
                              expected: "one of: \(items.compactMap { p.string(.title, of: $0) }.joined(separator: ", "))",
                              observed: "no match")
        }
        do { try p.perform(.press, on: hit) }
        catch { try? p.perform(.cancel, on: popup); throw error }

        // Logic updates the popup's displayed value ASYNCHRONOUSLY (~400ms live) after the item press —
        // wait until it changes from the pre-selection value (or a deadline) so the caller's verify
        // doesn't read the stale prior value. A no-op re-select (choice == current) just waits out the poll.
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline {
            if p.string(.value, of: popup) != priorValue { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Insert-plugin popup — SEARCH-DRIVEN (see Fixtures/ax/popup_plugin_search.txt).
    ///
    /// The old code pressed the slot and did `menuItems(under: slot)`, expecting the popup AXMenu to
    /// attach UNDER the pressed button. On real Logic 12.3 it does NOT: the popup attaches as a
    /// SIBLING OF THE MIXER STRIPS (a child of the mixer AXLayoutArea, at the same depth as each
    /// strip's AXLayoutItem), so the under-the-slot lookup found nothing forever — no sleep helps.
    /// It also walked "Recent + one category deep", which can't reach plugins that are neither.
    ///
    /// New algorithm, all no-focus (AXSetValue triggers Logic's filter with NO keystrokes/CGEvents):
    ///   1. Press the slot to open the popup (return code unreliable — read the tree).
    ///   2. Find the popup by walking the WINDOW tree: the AXMenu whose subtree holds an
    ///      AXTextField subrole="AXSearchField". Settle-poll (~2s) — the AX tree updates async.
    ///   3. setString the plugin name into the search field.
    ///   4. Settle-poll (~2s) until the filtered items contain an EXACT case-insensitive title match.
    ///   5. Pick the EXACT match — NOT the first result (typing "Compressor" also returns
    ///      "Multipressor"/"Squash Compressor"/…; first-result would insert the wrong plugin).
    ///   6. Press the channel-config leaf under it (prefer `config`, else the first leaf).
    /// Dismisses the popup (AXCancel on the slot) on ANY throw path so no modal menu lingers. The
    /// TOOL settle-polls `pluginGroups` afterwards as the independent oracle — not done here.
    public func selectPluginFromPopup(from slot: AXHandle, plugin: String,
                                      config: String = "Stereo") async throws {
        try? p.perform(.press, on: slot)       // opens the popup (return code is unreliable; read the tree)

        // 2. Locate the popup + its search field by walking the window tree (NOT under the slot).
        guard let popup = await settleForSearchPopup() else {
            throw ToolFailure(error: "plugin-insert popup did not open", layer: "ax",
                              expected: "an insert popup carrying a search field (AXSearchField)",
                              observed: "pressed the insert slot but no AXMenu with a search field appeared within 2s")
        }

        // 3. Drive the search field — this triggers Logic's filter with no keystrokes.
        do { try p.setString(plugin, of: popup.search) }
        catch {
            try? p.perform(.cancel, on: slot)
            throw ToolFailure(error: "could not type into the plugin search field", layer: "ax",
                              expected: "a settable AXSearchField", observed: "\(error)")
        }

        // 4+5. Settle-poll until an EXACT case-insensitive title match appears in the FILTERED items.
        var seen: [String] = []
        var match: AXHandle?
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            let items = searchPopupItems(in: popup.menu)
            seen = items.compactMap { p.string(.title, of: $0) }
            match = items.first { (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(plugin) == .orderedSame }
            if match != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline

        guard let pluginItem = match else {
            try? p.perform(.cancel, on: slot)
            throw ToolFailure(error: "plugin '\(plugin)' not found in the insert search results", layer: "ax",
                              expected: "an exact match for '\(plugin)' after filtering the insert search",
                              observed: "filtered results: \(seen.prefix(30).joined(separator: ", "))")
        }

        // 6. Press the channel-config leaf inside the matched plugin's submenu.
        let configs = menuItems(under: pluginItem)
        let leaf = configs.first { (p.string(.title, of: $0) ?? "").caseInsensitiveCompare(config) == .orderedSame }
            ?? configs.first
        guard let leaf else {
            try? p.perform(.cancel, on: slot)
            throw ToolFailure(error: "no channel configuration under '\(plugin)'", layer: "ax",
                              expected: "e.g. 'Stereo' or 'Dual Mono'", observed: "empty submenu")
        }
        try p.perform(.press, on: leaf)
    }

    /// Settle-poll (~2s) for the plugin-insert popup anywhere in the window tree — the AX tree
    /// updates ASYNCHRONOUSLY after the slot press, so an immediate read routinely misses it.
    private func settleForSearchPopup() async -> (menu: AXHandle, search: AXHandle)? {
        if let hit = findSearchPopup() { return hit }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let hit = findSearchPopup() { return hit }
        }
        return nil
    }

    /// The insert popup is the AXMenu (a sibling of the strips) whose subtree contains an
    /// AXTextField subrole="AXSearchField". Returns that menu and its search field.
    private func findSearchPopup() -> (menu: AXHandle, search: AXHandle)? {
        for w in p.windows() {
            if let hit = menuWithSearchField(w, 0) { return hit }
        }
        return nil
    }
    private func menuWithSearchField(_ h: AXHandle, _ d: Int) -> (menu: AXHandle, search: AXHandle)? {
        if d > 14 { return nil }
        if p.string(.role, of: h) == "AXMenu", let sf = firstSearchField(h, 0) { return (h, sf) }
        for c in p.children(of: h) { if let f = menuWithSearchField(c, d + 1) { return f } }
        return nil
    }
    private func firstSearchField(_ h: AXHandle, _ d: Int) -> AXHandle? {
        if d > 10 { return nil }
        if p.string(.role, of: h) == "AXTextField", p.string(.subrole, of: h) == "AXSearchField" { return h }
        for c in p.children(of: h) { if let f = firstSearchField(c, d + 1) { return f } }
        return nil
    }

    /// The selectable plugin items in the popup: its AXMenuItem children with a non-empty title.
    /// Skips the search-field item and separators (no title). "Activate Plug-ins"/"Recent" labels
    /// carry a title but collapse away once the search filter is applied (see the fixture), and even
    /// if present they have no config submenu so the config-leaf press below would refuse them.
    private func searchPopupItems(in popup: AXHandle) -> [AXHandle] {
        p.children(of: popup).filter {
            p.string(.role, of: $0) == "AXMenuItem" && !(p.string(.title, of: $0) ?? "").isEmpty
        }
    }
}
