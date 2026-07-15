import Foundation
@testable import LogicMCPCore

/// Parses the indented AX dumps in `Fixtures/ax/*.txt` (the exact shape `logic-mcp axdump`
/// prints from REAL Logic) into a `FakeAXNode` tree, so regression tests can be driven by
/// captured ground truth instead of a hand-built approximation of it. Used by the BUG 1
/// (output-slot identification) and BUG 2 (mini-mixer binding) tests against
/// `Fixtures/ax/strip_special.txt`.
///
/// Line format (two spaces per nesting level):
///   `AXButton subrole="AXSwitch" description="bounce" value="off" settable=false`
/// `#` comments and blank lines are ignored.
enum AXFixture {
    /// The top-level nodes of `Fixtures/ax/<name>.txt` (e.g. the two AXWindows).
    static func nodes(_ name: String) -> [FakeAXNode] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt",
                                          subdirectory: "Fixtures/ax"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("missing AX fixture '\(name).txt'")
        }
        return parse(text)
    }

    /// A provider whose `AXApplication` root holds the fixture's top-level nodes.
    static func provider(_ name: String) -> FakeAXProvider {
        FakeAXProvider(root: FakeAXNode(role: "AXApplication", children: nodes(name)))
    }

    /// Depth-first lookup by description (nil-safe), for pulling a strip/control out of a
    /// parsed tree so a test can instrument it (e.g. record whether it was ever pressed).
    static func find(_ roots: [FakeAXNode], description: String) -> FakeAXNode? {
        for r in roots {
            if r.description == description { return r }
            if let hit = find(r.children, description: description) { return hit }
        }
        return nil
    }

    /// Depth-first lookup by title (windows carry a title, not a description).
    static func find(_ roots: [FakeAXNode], title: String) -> FakeAXNode? {
        for r in roots {
            if r.title == title { return r }
            if let hit = find(r.children, title: title) { return hit }
        }
        return nil
    }

    // MARK: - parsing

    private static func parse(_ text: String) -> [FakeAXNode] {
        var roots: [FakeAXNode] = []
        var stack: [(depth: Int, node: FakeAXNode)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            let depth = indent / 2
            let node = node(from: trimmed)
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            if let parent = stack.last?.node { parent.children.append(node) } else { roots.append(node) }
            stack.append((depth, node))
        }
        return roots
    }

    private static func node(from line: String) -> FakeAXNode {
        let role = String(line.prefix { !$0.isWhitespace })
        var attrs: [String: String] = [:]
        // key="value" pairs (values may contain spaces, never a quote).
        let re = try! NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        let ns = line as NSString
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            attrs[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        let settable = line.contains("settable=true")
        let value = attrs["value"]
        // A dumped `value="173"` on a slider is the NUMERIC AX value; on a switch it's the string
        // "on"/"off". Populate both fields when it parses as a number so `number(of:)` (pan, fader)
        // and the string `.value` read (mute/solo) both see what real Logic exposes.
        return FakeAXNode(role: role,
                          subrole: attrs["subrole"],
                          description: attrs["description"],
                          title: attrs["title"],
                          stringValue: value,
                          value: value.flatMap(Double.init),
                          settable: settable)
    }
}
