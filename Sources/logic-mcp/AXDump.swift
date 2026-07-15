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
