import XCTest
@testable import ChompCore

final class QuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testCodexWindowsAndMissingWindow() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":82,"windowDurationMins":300,"resetsAt":1800007200},"secondary":null}}}"#.utf8)
        let q = try QuotaParser.codex(data, now: now)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q[0].title, "5-hour")
        XCTAssertEqual(q[0].remaining, 18)
        XCTAssertEqual(q[0].resetsAt, now.addingTimeInterval(7200))
        XCTAssertEqual(q[0].observedAt, now)
    }
    func testClaudeIgnoresContextAndPrivateFields() throws {
        let data = Data(#"{"prompt":"private","context_window":{"used_percentage":99},"rate_limits":{"five_hour":{"used_percentage":71.5,"resets_at":1800007200}}}"#.utf8)
        let q = try QuotaParser.claude(data, now: now)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q[0].used, 71.5)
        XCTAssertEqual(q[0].title, "Session")
        XCTAssertFalse(q[0].isStale(at: now.addingTimeInterval(14 * 60)))
        XCTAssertTrue(q[0].isStale(at: now.addingTimeInterval(16 * 60)))
        let stored = String(decoding: try JSONEncoder().encode(q), as: UTF8.self)
        XCTAssertFalse(stored.contains("private"))
        XCTAssertFalse(stored.contains("context_window"))
        XCTAssertEqual(try QuotaParser.claude(Data(#"{"context_window":{"used_percentage":99}}"#.utf8)).count, 0)
    }
    func testInvalidPercentagesNeverBecomeZeroUsage() throws {
        for value in ["-1", "101", "true", "\"42\"", "null"] {
            let payload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(value)}}}"
            XCTAssertTrue(try QuotaParser.claude(Data(payload.utf8)).isEmpty)
        }
        XCTAssertThrowsError(try QuotaParser.codex(Data(#"{"error":{"code":401}}"#.utf8)))
    }
    func testClaudeModelWindowsAndScopedBuckets() throws {
        let data = Data(#"{"rate_limits":{"seven_day":{"used_percentage":41},"seven_day_opus":{"used_percentage":12.5,"resets_at":1800007200},"model_scoped":[{"display_name":"Fable","utilization":0.628,"resets_at":"2027-01-15T08:00:00Z","internal_id":"secret"},{"display_name":"","utilization":0.5},{"display_name":"Fable","utilization":0.9}]}}"#.utf8)
        let q = try QuotaParser.claude(data, now: now)
        XCTAssertEqual(q.map(\.title), ["Weekly", "Opus weekly", "Fable weekly"])
        XCTAssertEqual(q[2].used, 62.8, accuracy: 0.001)
        XCTAssertEqual(q[2].id, "model:Fable")
        XCTAssertNotNil(q[2].resetsAt)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(q), as: UTF8.self).contains("secret"))
        XCTAssertEqual(try QuotaParser.claude(Data(#"{"rate_limits":{"model_scoped":[{"display_name":"Fable","utilization":85}]}}"#.utf8))[0].used, 85)
    }
    func testClaudeSnapshotModelRowsOnly() throws {
        let data = Data(#"{"oauthAccount":{"emailAddress":"secret@example.com"},"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"accountUuid":"secret-uuid","utilization":{"five_hour":{"utilization":10},"limits":[{"kind":"session","percent":10,"resets_at":null,"scope":null},{"kind":"weekly_all","percent":70,"resets_at":null,"scope":null},{"kind":"weekly_scoped","percent":100,"resets_at":"2027-01-20T16:59:59.855420+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":140,"scope":{"model":{"display_name":"Bad"}}}]}}}"#.utf8)
        let q = try QuotaParser.claudeSnapshot(data)
        XCTAssertEqual(q.map(\.title), ["Fable weekly"])
        XCTAssertEqual(q[0].used, 100)
        XCTAssertEqual(q[0].observedAt, now)
        XCTAssertNotNil(q[0].resetsAt)
        XCTAssertFalse(q[0].isStale(at: now.addingTimeInterval(6 * 3600)))
        XCTAssertTrue(q[0].isStale(at: q[0].resetsAt!))
        let stored = String(decoding: try JSONEncoder().encode(q), as: UTF8.self)
        XCTAssertFalse(stored.contains("secret"))
        XCTAssertTrue(try QuotaParser.claudeSnapshot(Data(#"{"numStartups":3}"#.utf8)).isEmpty)
    }
    func testGhostThresholdAndClosingGap() {
        XCTAssertFalse(Quota(id: "a", title: "test", used: 69).hasGhost)
        let warning = Quota(id: "a", title: "test", used: 70)
        let danger = Quota(id: "a", title: "test", used: 95)
        XCTAssertTrue(warning.hasGhost)
        XCTAssertGreaterThan(warning.ghostGap, danger.ghostGap)
        XCTAssertEqual(Quota(id: "a", title: "test", used: 100).remaining, 0)
        XCTAssertEqual(Quota(id: "a", title: "test", used: 100).ghostGap, 0)
    }
    func testStalenessAndExpiredReset() {
        let q = Quota(id: "a", title: "test", used: 10, observedAt: now)
        XCTAssertFalse(q.isStale(at: now.addingTimeInterval(300)))
        XCTAssertTrue(q.isStale(at: now.addingTimeInterval(301)))
        let expired = Quota(id: "a", title: "test", used: 10, resetsAt: now, observedAt: now)
        XCTAssertTrue(expired.isStale(at: now))
    }
    func testISOResetAndFractionalSeconds() throws {
        for date in ["2027-01-15T08:00:00Z", "2027-01-15T08:00:00.123Z"] {
            let data = Data("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":\"\(date)\"}}}".utf8)
            XCTAssertNotNil(try QuotaParser.claude(data)[0].resetsAt)
        }
    }
}
