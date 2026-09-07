import XCTest
@testable import CodexLimitBar

final class CodexLimitBarTests: XCTestCase {
    func testParsingAndRecommendationUseTheBottleneckLimit() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":26,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":120}},"rate_limit_reset_credits":{"available_count":2}}"#.utf8)
        let parsed = try CodexUsageClient.parseUsage(data, now: now)
        XCTAssertEqual(parsed.session?.remaining, 74)
        XCTAssertEqual(parsed.weekly?.remaining, 0)
        XCTAssertEqual(parsed.resetCredits?.available, 2)

        let resets = try CodexUsageClient.parseResetCredits(Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"2033-05-18T03:34:00.000Z"},{"expires_at":"2033-05-19T03:34:00Z"},{"status":"redeemed","expires_at":"2033-05-20T03:34:00Z"}]}"#.utf8))
        XCTAssertEqual(resets.available, 2)
        XCTAssertEqual(resets.expiries.count, 2)
        XCTAssertNotEqual(
            CodexUsageClient.identityKey(accountID: "shared-workspace", subject: "user-a", email: "a@example.com"),
            CodexUsageClient.identityKey(accountID: "shared-workspace", subject: "user-b", email: "b@example.com")
        )

        let current = AccountSnapshot(id: "a", email: "a@example.com", session: parsed.session, weekly: parsed.weekly, updatedAt: now)
        let usable = AccountSnapshot(id: "b", email: "b@example.com", session: .init(remaining: 20, resetsAt: nil), weekly: .init(remaining: 68, resetsAt: nil), updatedAt: now)
        let best = AccountSnapshot(id: "d", email: "d@example.com", session: .init(remaining: 65, resetsAt: nil), weekly: .init(remaining: 90, resetsAt: nil), updatedAt: now)
        let temptingButBlocked = AccountSnapshot(id: "c", email: "c@example.com", session: .init(remaining: 100, resetsAt: nil), weekly: .init(remaining: 0, resetsAt: now.addingTimeInterval(500)), updatedAt: now)
        let accounts = [usable, temptingButBlocked, current, best]
        XCTAssertEqual(AccountChooser.ordered(accounts: accounts, currentID: "a", now: now).map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(AccountChooser.next(accounts: accounts, excluding: "a", now: now), .switchNow(best))

        let ready = AccountSnapshot(id: "e", email: "e@example.com", session: .init(remaining: 0, resetsAt: now.addingTimeInterval(-1)), weekly: .init(remaining: 50, resetsAt: nil), updatedAt: now)
        let weeklyBlocked = AccountSnapshot(id: "f", email: "f@example.com", session: .init(remaining: 0, resetsAt: now.addingTimeInterval(-1)), weekly: .init(remaining: 0, resetsAt: now.addingTimeInterval(60)), updatedAt: now)
        XCTAssertEqual(AccountChooser.readyForNewSession(accounts: [current, ready, weeklyBlocked], currentID: "a", now: now).map(\.id), ["e"])
    }
}
