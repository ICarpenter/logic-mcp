import Foundation

/// When the running code was built, versus when the binary sitting on disk was built.
///
/// `logic-mcp serve` is a long-lived process: the MCP client starts it once and keeps it. A
/// `swift build` therefore replaces the file at the executable's path WITHOUT touching the
/// process — which keeps executing the code it was loaded with. That is not hypothetical; a
/// server launched at 14:01 served the 19:58 rebuild's predecessor for 18 hours, advertising
/// tools that had been deleted and hiding tools that had been added. Only reconnecting the MCP
/// server fixes it.
///
/// The signal that catches it: stat the executable ONCE at launch (that mtime belongs to the
/// build the running code came from), then re-stat the same path per `ping`. A rebuild writes a
/// NEW file at that path — new inode, new mtime — so `disk > running` means the process is
/// behind the source tree.
///
/// This type owns every filesystem touch, so `PingTool` can take plain values and be tested
/// with no filesystem at all (including the failure branches, which are near-impossible to
/// stage for real).
public struct BuildStamp: Sendable {
    /// mtime of the executable as captured at launch — nil if the path could not be resolved
    /// or stat'd. Nil is not fatal: staleness simply never fires. A health check must never
    /// take the server down.
    public let runningBuildTime: Date?

    /// Re-stat of the executable path, evaluated fresh on every call — this is the half that
    /// must NOT be cached, or the rebuild would be invisible. Nil when the stat fails.
    public let diskBuildTime: @Sendable () -> Date?

    public init(runningBuildTime: Date?, diskBuildTime: @escaping @Sendable () -> Date?) {
        self.runningBuildTime = runningBuildTime
        self.diskBuildTime = diskBuildTime
    }

    /// The real stamp: resolves the running executable and stats it now (for the launch
    /// baseline) and on demand (for the disk reading).
    public static func live() -> BuildStamp {
        let path = executablePath()
        return BuildStamp(
            runningBuildTime: path.flatMap { modificationDate(ofPath: $0) },
            diskBuildTime: { path.flatMap { modificationDate(ofPath: $0) } }
        )
    }

    /// A stamp that knows nothing — for tests and any context with no executable to speak of.
    public static let unknown = BuildStamp(runningBuildTime: nil, diskBuildTime: { nil })

    /// `Bundle.main.executableURL` is the reliable answer for a Swift PM binary; `argv[0]` is
    /// the fallback (it can be a bare name if something exec'd us oddly, in which case the
    /// stat below just fails and staleness stays silent).
    public static func executablePath() -> String? {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first
    }

    public static func modificationDate(ofPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
