import MCP

public struct UndoLastTool: LogicTool {
    public let name = "undo_last"
    public let description = "Undo the last n mix mutations made through this daemon by restoring their prior values over the MCU wire. Plugin-param changes cannot be deterministically restored and are reported as skipped."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["n": .object(["type": .string("integer"), "default": .int(1), "minimum": .int(0)])]),
    ])
    let daemon: Daemon
    let registry: ToolRegistry

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let n = args["n"]?.coercedInt ?? 1
        var undone: [Value] = []
        var skipped: [Value] = []
        for mutation in await daemon.journal.popLast(n) {
            guard let undoArgs = mutation.undoArguments else {
                skipped.append(.string(mutation.descriptionText))
                continue
            }
            var callArgs: [String: Value] = [:]
            for (key, raw) in undoArgs {
                if raw == "true" || raw == "false" { callArgs[key] = .bool(raw == "true") }
                else if let d = Double(raw), key != "track", key != "bus", key != "param" {
                    callArgs[key] = key == "level" || key == "position" ? .int(Int(d)) : .double(d)
                } else { callArgs[key] = .string(raw) }
            }
            let result = await registry.call(name: mutation.tool, arguments: callArgs)
            if result.isError == true {
                skipped.append(.string("\(mutation.descriptionText) — undo failed"))
            } else {
                undone.append(.string(mutation.descriptionText))
            }
        }
        return .object(["undone": .array(undone), "skipped": .array(skipped)])
    }
}
