import XCTest
import MCP
@testable import LogicMCPCore

/// `ping` is the daemon's only self-report, and the one health problem this project actually
/// has is a STALE PROCESS: `logic-mcp serve` is long-lived, so a `swift build` replaces the
/// binary on disk while the running process keeps executing the old in-memory code (it once
/// served 18 hours of pre-Phase-3 tools). A ping that answers a hardcoded `ok/version` is a
/// health check that cannot see the only illness — exactly the "trusted success code" this
/// codebase forbids everywhere else.
///
/// So `ping` compares the mtime captured at LAUNCH (the build the running code came from)
/// against a per-call re-stat of the same path (the build sitting on disk NOW). The times are
/// INJECTED — PingTool must never touch the filesystem — which is what lets these tests drive
/// every branch, including the ones that are near-impossible to stage for real (a failed stat,
/// a backwards clock).
final class PingToolTests: XCTestCase {
    let runningAt = Date(timeIntervalSince1970: 1_752_415_317)   // 2025-07-13T14:01:57Z

    /// Invoke `ping` through the real registry (not the struct directly) so the assertions run
    /// against the JSON a client would actually receive, encoding included.
    func ping(running: Date?, disk: Date?) async throws -> [String: Any] {
        let registry = ToolRegistry()
        await registry.register(PingTool(version: "0.1.0",
                                         runningBuildTime: running,
                                         diskBuildTime: { disk }))
        let result = await registry.call(name: "ping", arguments: [:])
        XCTAssertNotEqual(result.isError, true, "ping must never report failure")
        guard case .text(let json, _, _)? = result.content.first else {
            throw ToolFailure(error: "expected text content", layer: "daemon")
        }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: - The signal

    func testDiskNewerThanRunningIsStaleAndHints() async throws {
        let json = try await ping(running: runningAt, disk: runningAt.addingTimeInterval(21_418))
        XCTAssertEqual(json["stale"] as? Bool, true)
        // XCTUnwrap, not `!`: a missing hint must FAIL this test, not crash the whole runner
        // and take the other 170-odd tests with it.
        let hint = try XCTUnwrap(json["hint"] as? String,
                                 "a stale server must say so, and say what to do about it")
        XCTAssertTrue(hint.contains("reconnect"), "hint must name the remedy: got \(hint)")
        XCTAssertEqual(json["runningCodeBuiltAt"] as? String, "2025-07-13T14:01:57Z")
        XCTAssertEqual(json["binaryOnDiskBuiltAt"] as? String, "2025-07-13T19:58:55Z")
        // Backwards compat: existing callers still get ok/version, and a stale server is still
        // "ok" — it is answering, just out of date.
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["version"] as? String, "0.1.0")
    }

    func testDiskEqualToRunningIsFreshAndSilent() async throws {
        let json = try await ping(running: runningAt, disk: runningAt)
        XCTAssertEqual(json["stale"] as? Bool, false)
        XCTAssertNil(json["hint"], "a fresh server must not nag")
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    // MARK: - Do not cry wolf

    func testDiskStatFailureIsNotStale() async throws {
        // The executable path could not be stat'd (moved, deleted mid-session, sandbox). We
        // know nothing — so claim nothing. A health check that shouts "stale!" on missing
        // evidence trains the operator to ignore it, which is worse than silence.
        let json = try await ping(running: runningAt, disk: nil)
        XCTAssertEqual(json["ok"] as? Bool, true, "a broken stat must not fail the health check")
        XCTAssertEqual(json["stale"] as? Bool, false)
        XCTAssertNil(json["hint"])
        XCTAssertNil(json["binaryOnDiskBuiltAt"], "unknown must be absent, not a fabricated date")
    }

    func testDiskOlderThanRunningIsNotStale() async throws {
        // Clock skew, a restored older binary, a checkout of an older tree: the disk build is
        // BEHIND the running one. That is not the failure we are hunting (the running code is
        // not out of date), so it must not fire.
        let json = try await ping(running: runningAt, disk: runningAt.addingTimeInterval(-3_600))
        XCTAssertEqual(json["stale"] as? Bool, false)
        XCTAssertNil(json["hint"])
    }

    func testUnresolvableLaunchStampNeverFires() async throws {
        // If the executable path could not be resolved AT LAUNCH we have no baseline, so
        // staleness can never be computed. The daemon must still boot and still answer ping —
        // a broken health check must never take the server down.
        let json = try await ping(running: nil, disk: runningAt.addingTimeInterval(21_418))
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["stale"] as? Bool, false)
        XCTAssertNil(json["hint"])
        XCTAssertNil(json["runningCodeBuiltAt"])
    }

    // MARK: - Discoverability

    func testDescriptionAdvertisesStaleness() async throws {
        // The agent calling `ping` only ever sees this string; if it does not mention
        // staleness, nobody will think to ask ping about it.
        let tool = PingTool(version: "0.1.0", runningBuildTime: runningAt, diskBuildTime: { nil })
        XCTAssertTrue(tool.description.lowercased().contains("stale"),
                      "ping's description must advertise the staleness report: '\(tool.description)'")
    }

    // MARK: - The real wiring
    //
    // Everything above is filesystem-free by construction. This one test earns its keep by
    // proving the LIVE stamp (the thing the daemon actually boots with) resolves a real path
    // and a real mtime — otherwise the injected-times design could be perfect while the
    // composition root silently feeds it nils forever.

    func testLiveBuildStampResolvesTheRunningExecutable() throws {
        let stamp = BuildStamp.live()
        XCTAssertNotNil(stamp.runningBuildTime, "could not stat the running xctest executable")
        XCTAssertNotNil(stamp.diskBuildTime(), "re-stat of the same path must succeed")
        XCTAssertEqual(stamp.runningBuildTime, stamp.diskBuildTime(),
                       "nothing rebuilt mid-test, so the two stats must agree")
    }
}
