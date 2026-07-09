import MCP

public struct PingTool: LogicTool {
    public let name = "ping"
    public let description = "Health check. Returns daemon version."
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])
    let version: String

    public init(version: String) { self.version = version }

    public func invoke(_ args: [String: Value]) async throws -> Value {
        .object(["ok": .bool(true), "version": .string(version)])
    }
}
