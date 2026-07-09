import Foundation
import MCP

public protocol LogicTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: Value { get }
    func invoke(_ args: [String: Value]) async throws -> Value
}

/// The spec's structured error contract: {error, layer, expected, observed}.
public struct ToolFailure: Error, Codable, Sendable {
    public var error: String
    public var layer: String   // "mcu" | "model" | "daemon"
    public var expected: String?
    public var observed: String?

    public init(error: String, layer: String, expected: String? = nil, observed: String? = nil) {
        self.error = error
        self.layer = layer
        self.expected = expected
        self.observed = observed
    }

    var json: String {
        let data = try! JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

public actor ToolRegistry {
    private var tools: [String: LogicTool] = [:]

    public init() {}

    public func register(_ tool: LogicTool) {
        tools[tool.name] = tool
    }

    public func list() -> [Tool] {
        tools.values
            .sorted { $0.name < $1.name }
            .map { Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let tool = tools[name] else {
            let failure = ToolFailure(error: "unknown tool '\(name)'", layer: "daemon")
            return .init(content: [textContent(failure.json)], isError: true)
        }
        do {
            let value = try await tool.invoke(arguments ?? [:])
            let data = try JSONEncoder().encode(value)
            return .init(content: [textContent(String(data: data, encoding: .utf8)!)], isError: false)
        } catch let failure as ToolFailure {
            return .init(content: [textContent(failure.json)], isError: true)
        } catch {
            let failure = ToolFailure(error: String(describing: error), layer: "daemon")
            return .init(content: [textContent(failure.json)], isError: true)
        }
    }

    /// The SDK's `Tool.Content.text` case carries labeled `annotations`/`_meta`
    /// alongside the text; this project never needs either, so centralize the
    /// labeled call here.
    private func textContent(_ s: String) -> Tool.Content {
        .text(text: s, annotations: nil, _meta: nil)
    }
}
