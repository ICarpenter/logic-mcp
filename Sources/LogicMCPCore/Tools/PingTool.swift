import Foundation
import MCP

/// Health check — and specifically an HONEST one about the failure this daemon actually has.
///
/// `logic-mcp serve` is long-lived, so a `swift build` swaps the binary on disk while the
/// running process keeps executing its old in-memory code. The old ping answered a hardcoded
/// `{ok: true, version: "0.1.0"}`, which is to say it reported perfect health while serving
/// 18-hour-stale tools. In a codebase whose doctrine is "never trust a success code, verify
/// against an independent oracle," that made the daemon the one liar in the building.
///
/// The oracle here is the filesystem: the executable's mtime as captured at LAUNCH (the build
/// the running code came from) versus a re-stat of the same path on every call (the build on
/// disk now). Both are INJECTED (see `BuildStamp`) so this type never touches the filesystem
/// and every branch — including a failed stat and a backwards clock — is directly testable.
public struct PingTool: LogicTool {
    public let name = "ping"
    public let description = """
        Health check. Returns daemon version, and reports whether the running server is STALE \
        (its code predates the binary on disk — i.e. someone rebuilt while this process kept \
        running the old code). If stale, reconnect the MCP server to load current code.
        """
    public let inputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])
    let version: String
    /// Captured once, at launch. Nil when the executable path could not be resolved/stat'd —
    /// in which case staleness never fires (see `invoke`).
    let runningBuildTime: Date?
    /// Re-evaluated on EVERY call — caching this would defeat the entire point.
    let diskBuildTime: @Sendable () -> Date?

    public init(version: String,
                runningBuildTime: Date? = nil,
                diskBuildTime: @escaping @Sendable () -> Date? = { nil }) {
        self.version = version
        self.runningBuildTime = runningBuildTime
        self.diskBuildTime = diskBuildTime
    }

    public func invoke(_ args: [String: Value]) async throws -> Value {
        let disk = diskBuildTime()

        // Stale ONLY when both times are known and disk is strictly newer. Every unknown
        // (launch stamp unresolved, stat failed) and the backwards case (clock skew, an older
        // binary restored) resolve to "not stale": a health check that cries wolf on missing
        // evidence gets ignored, which leaves us worse off than the lie it replaced.
        var stale = false
        if let running = runningBuildTime, let disk { stale = disk > running }

        var out: [String: Value] = [
            "ok": .bool(true),          // kept for backwards compat; a stale server still answers
            "version": .string(version),
            "stale": .bool(stale),
        ]
        // Report only what we actually observed — an unknown time is absent, never fabricated.
        // `.iso8601` (the FormatStyle, not ISO8601DateFormatter) is a Sendable value type, so
        // it needs no shared mutable formatter instance.
        if let running = runningBuildTime {
            out["runningCodeBuiltAt"] = .string(running.formatted(.iso8601))
        }
        if let disk {
            out["binaryOnDiskBuiltAt"] = .string(disk.formatted(.iso8601))
        }
        if stale {
            out["hint"] = .string("the running server predates the binary on disk — "
                                  + "reconnect the MCP server (/mcp) to load current code")
        }
        return .object(out)
    }
}
