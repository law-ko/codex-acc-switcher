import XCTest
@testable import CodexLimitBar

final class CodexLimitBarTests: XCTestCase {
    func testParsingAndRecommendationUseTheBottleneckLimit() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":26,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":120}}}"#.utf8)
        let parsed = try CodexUsageClient.parseUsage(data, now: now)
        XCTAssertEqual(parsed.session?.remaining, 74)
        XCTAssertEqual(parsed.weekly?.remaining, 0)

        let current = AccountSnapshot(id: "a", email: "a@example.com", session: parsed.session, weekly: parsed.weekly, updatedAt: now)
        let usable = AccountSnapshot(id: "b", email: "b@example.com", session: .init(remaining: 20, resetsAt: nil), weekly: .init(remaining: 68, resetsAt: nil), updatedAt: now)
        let temptingButBlocked = AccountSnapshot(id: "c", email: "c@example.com", session: .init(remaining: 100, resetsAt: nil), weekly: .init(remaining: 0, resetsAt: now.addingTimeInterval(500)), updatedAt: now)
        XCTAssertEqual(AccountChooser.next(accounts: [current, usable, temptingButBlocked], excluding: "a", now: now), .switchNow(usable))
    }
}
