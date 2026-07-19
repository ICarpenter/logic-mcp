import ArgumentParser
import Foundation
import LogicMCPCore

struct AXDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "axdump",
        abstract: "Dump Logic's accessibility tree (AX analog of lcdprobe). Read-only walk.")

    @Argument(help: "mode: tree | strip <name> | plugin <name> <slot> | send <name> | menu <name>")
    var args: [String] = ["tree"]

    func run() async throws {
        let p = try SystemAXProvider()
        let mode = args.first ?? "tree"
        switch mode {
        case "tree":
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 5) }
        case "deep":
            // Diagnostic: dump a window whose title contains args[1], to depth args[2] (default 12).
            // Read-only; used to probe the arrange-canvas subtree the depth-5 `tree` cap cuts off.
            let needle = (args.count >= 2 ? args[1] : "").lowercased()
            let maxD = (args.count >= 3 ? Int(args[2]) : nil) ?? 12
            for w in p.windows() where (p.string(.title, of: w) ?? "").lowercased().contains(needle) {
                dump(p, w, depth: 0, maxDepth: maxD)
            }
        case "strip", "send":
            guard args.count >= 2, let strip = findStrip(p, named: args[1]) else {
                print("strip '\(args.dropFirst().first ?? "?")' not found"); return
            }
            dump(p, strip, depth: 0, maxDepth: 4)
        case "plugin":
            print("Open the plugin window in Logic first, then run `axdump tree` and locate")
            print("the plugin window; this mode just re-dumps all windows for capture:")
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 6) }
        case "insertprobe":
            // Diagnostic: open a strip's first insert popup and dump it, to capture the real
            // (search-based) plugin picker. Optional 3rd arg = a query typed into the first text
            // field found in the popup, so we can see how results populate after typing.
            guard args.count >= 2, let strip = findStrip(p, named: args[1]) else {
                print("strip '\(args.dropFirst().first ?? "?")' not found"); return
            }
            guard let slot = firstControl(p, in: strip, description: "audio plug-in") else {
                print("no 'audio plug-in' insert slot on '\(args[1])'"); return
            }
            try? p.perform(.press, on: slot)   // return code unreliable; the popup opens anyway
            usleep(1_300_000)
            print("========== POPUP (before typing) ==========")
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 8) }
            if args.count >= 3 {
                let query = args[2]
                if let field = firstSearchField(p, in: p.windows()) {
                    print("========== typing '\(query)' into \(p.string(.subrole, of: field) ?? "?") ==========")
                    try? p.setString(query, of: field)
                    usleep(1_300_000)
                    print("========== POPUP (after typing) ==========")
                    for w in p.windows() { dump(p, w, depth: 0, maxDepth: 8) }
                } else {
                    print("no text/search field found in popup to type into")
                }
            }
        case "outputprobe":
            // Diagnostic: press a strip's output-routing button and dump ALL windows, to capture
            // WHERE the routing popup attaches (under the button? a sibling of the strips? a separate
            // window?) and its nested structure — the ground truth set_output/selectPopupLeaf needs.
            guard args.count >= 2, let strip = findStrip(p, named: args[1]) else {
                print("strip '\(args.dropFirst().first ?? "?")' not found"); return
            }
            guard let btn = outputButton(p, in: strip) else {
                print("no output-routing button on '\(args[1])' (no plain AXButton after the 'group' popup)"); return
            }
            print("output button: desc=\(p.string(.description, of: btn).debugDescription)")
            try? p.perform(.press, on: btn)   // return code unreliable; the popup opens anyway
            usleep(1_300_000)
            print("========== ALL WINDOWS after pressing output button ==========")
            for w in p.windows() { dump(p, w, depth: 0, maxDepth: 9) }
            if args.count >= 3, let field = firstSearchField(p, in: p.windows()) {
                print("========== typing '\(args[2])' into the routing search field ==========")
                try? p.setString(args[2], of: field)
                usleep(1_300_000)
                for w in p.windows() { dump(p, w, depth: 0, maxDepth: 9) }
            }
            try? p.perform(.cancel, on: btn)   // dismiss so we don't leave a modal popup hanging
        case "press":
            // Diagnostic: find the first element whose description CONTAINS args[2] inside a window
            // whose title contains args[1], press it, settle, then dump that window to depth args[3]
            // (default 18). Read/actuate for feasibility probes (e.g. toggle "List Editors").
            let needle = (args.count >= 2 ? args[1] : "").lowercased()
            var descNeedle = (args.count >= 3 ? args[2] : "").lowercased()
            var exact = false
            if descNeedle.hasPrefix("=") { exact = true; descNeedle.removeFirst() }
            let maxD = (args.count >= 4 ? Int(args[3]) : nil) ?? 18
            let roleFilter = (args.count >= 5 ? args[4] : nil)   // e.g. "AXRadioButton" to disambiguate
            let occurrence = (args.count >= 6 ? Int(args[5]) : nil) ?? 0   // 0-based: which match to press
            let wins = p.windows().filter { (p.string(.title, of: $0) ?? "").lowercased().contains(needle) }
            let matches = wins.flatMap { allByDescription(p, in: $0, contains: descNeedle, role: roleFilter, exact: exact) }
            guard occurrence < matches.count else {
                print("only \(matches.count) match(es) for '\(descNeedle)' (role \(roleFilter ?? "any")); wanted index \(occurrence)"); return
            }
            let target = matches[occurrence]
            print("pressing: \(p.string(.role, of: target) ?? "?") desc=\(p.string(.description, of: target).debugDescription) value=\(p.string(.value, of: target).debugDescription)")
            try? p.perform(.press, on: target)
            usleep(900_000)
            for w in wins { dump(p, w, depth: 0, maxDepth: maxD) }
        case "setvalue":
            // Diagnostic: AXSetValue a number on a located element, then re-read — reveals whether the
            // control is ABSOLUTE (lands at v) or ±1-NUDGE, and its min/max/settable. Task 0 gate.
            guard args.count >= 4, let v = Double(args[3]) else {
                print("usage: setvalue <winNeedle> <=desc|desc> <number> [role]"); return
            }
            let needle = args[1].lowercased()
            var desc = args[2].lowercased(); var exact = false
            if desc.hasPrefix("=") { exact = true; desc.removeFirst() }
            let role = args.count >= 5 ? args[4] : nil
            let wins = p.windows().filter { (p.string(.title, of: $0) ?? "").lowercased().contains(needle) }
            guard let target = wins.compactMap({ firstByDescription(p, in: $0, contains: desc, role: role, exact: exact) }).first else {
                print("no element desc containing '\(desc)' in '\(needle)'"); return
            }
            print("before: value=\(p.number(of: target).debugDescription) settable=\(p.isSettable(target)) minmax=\(p.minMax(of: target))")
            try? p.setNumber(v, of: target)
            usleep(400_000)
            print("after setNumber(\(v)): value=\(p.number(of: target).debugDescription)")
        case "setstring":
            // Diagnostic: AXSetValue a string on a located element (e.g. a track name field), then
            // re-read — reveals whether the edit COMMITS no-focus. Task 0 rename gate.
            guard args.count >= 4 else { print("usage: setstring <winNeedle> <=desc|desc> <string> [role]"); return }
            let needle = args[1].lowercased()
            var desc = args[2].lowercased(); var exact = false
            if desc.hasPrefix("=") { exact = true; desc.removeFirst() }
            let role = args.count >= 5 ? args[4] : nil
            let wins = p.windows().filter { (p.string(.title, of: $0) ?? "").lowercased().contains(needle) }
            guard let target = wins.compactMap({ firstByDescription(p, in: $0, contains: desc, role: role, exact: exact) }).first else {
                print("no element desc containing '\(desc)' in '\(needle)'"); return
            }
            print("before: value=\(p.string(.value, of: target).debugDescription) desc=\(p.string(.description, of: target).debugDescription)")
            try? p.setString(args[3], of: target)
            usleep(500_000)
            print("after setString('\(args[3])'): value=\(p.string(.value, of: target).debugDescription) desc=\(p.string(.description, of: target).debugDescription)")
        case "menu":
            guard args.count >= 2 else { print("usage: axdump menu <Track|File|Mix|Edit>"); return }
            guard let mb = p.menuBar() else { print("no menu bar"); return }
            let name = args[1]
            guard let item = p.children(of: mb).first(where: { p.string(.title, of: $0) == name }) else {
                print("menu '\(name)' not found"); return
            }
            // AXMenuBarItem → AXMenu → AXMenuItems
            for sub in p.children(of: item) { dump(p, sub, depth: 0, maxDepth: 3) }
        default:
            print("unknown mode '\(mode)'")
        }
    }

    private func findStrip(_ p: SystemAXProvider, named: String) -> AXHandle? {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 8 { return nil }
            if p.string(.role, of: h) == "AXLayoutItem",
               p.string(.description, of: h)?.lowercased() == named.lowercased() { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return p.windows().compactMap { rec($0, 0) }.first
    }

    private func firstControl(_ p: SystemAXProvider, in strip: AXHandle, description: String) -> AXHandle? {
        p.children(of: strip).first { p.string(.description, of: $0)?.lowercased() == description.lowercased() }
    }

    /// The strip's output-routing button: the plain AXButton immediately after the "group" popup
    /// (same structural anchor AXBridge.outputButton uses).
    private func outputButton(_ p: SystemAXProvider, in strip: AXHandle) -> AXHandle? {
        let kids = p.children(of: strip)
        guard let gi = kids.firstIndex(where: {
            p.string(.role, of: $0) == "AXPopUpButton" && p.string(.description, of: $0) == "group"
        }) else { return nil }
        let ni = kids.index(after: gi)
        guard ni < kids.endIndex, p.string(.role, of: kids[ni]) == "AXButton" else { return nil }
        return kids[ni]
    }

    /// Collect ALL elements matching the description (+ optional role/exact), in tree order — so a
    /// probe can press the Nth occurrence (e.g. the 2nd "Has Focus" radio = the 2nd track).
    private func allByDescription(_ p: SystemAXProvider, in root: AXHandle, contains: String, role: String? = nil, exact: Bool = false) -> [AXHandle] {
        var out: [AXHandle] = []
        func rec(_ h: AXHandle, _ d: Int) {
            if d > 16 { return }
            if let desc = p.string(.description, of: h)?.lowercased(), (exact ? desc == contains : desc.contains(contains)),
               role == nil || p.string(.role, of: h) == role { out.append(h) }
            for c in p.children(of: h) { rec(c, d + 1) }
        }
        rec(root, 0)
        return out
    }

    private func firstByDescription(_ p: SystemAXProvider, in root: AXHandle, contains: String, role: String? = nil, exact: Bool = false) -> AXHandle? {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 14 { return nil }
            if let desc = p.string(.description, of: h)?.lowercased(), (exact ? desc == contains : desc.contains(contains)),
               role == nil || p.string(.role, of: h) == role { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return rec(root, 0)
    }

    private func firstSearchField(_ p: SystemAXProvider, in roots: [AXHandle]) -> AXHandle? {
        func rec(_ h: AXHandle, _ d: Int) -> AXHandle? {
            if d > 12 { return nil }
            if p.string(.subrole, of: h) == "AXSearchField" { return h }
            for c in p.children(of: h) { if let f = rec(c, d + 1) { return f } }
            return nil
        }
        return roots.compactMap { rec($0, 0) }.first
    }

    private func dump(_ p: SystemAXProvider, _ h: AXHandle, depth: Int, maxDepth: Int) {
        let pad = String(repeating: "  ", count: depth)
        var line = p.string(.role, of: h) ?? "?"
        for a in [AXAttr.subrole, .description, .title, .value] {
            if let v = p.string(a, of: h), !v.isEmpty { line += " \(a)=\(v.prefix(48).debugDescription)" }
        }
        line += " settable=\(p.isSettable(h))"
        print(pad + line)
        guard depth < maxDepth else { return }
        for c in p.children(of: h) { dump(p, c, depth: depth + 1, maxDepth: maxDepth) }
    }
}
