import Foundation

struct LimitWindow: Codable, Equatable {
    var remaining: Double
    var resetsAt: Date?

    func effectiveRemaining(at date: Date) -> Double {
        if let resetsAt, resetsAt <= date { return 100 }
        return min(100, max(0, remaining))
    }
}

struct ResetCredits: Codable, Equatable {
    var available: Int
    var expiries: [Date]
}

struct AccountSnapshot: Codable, Identifiable, Equatable {
    var id: String
    var email: String
    var session: LimitWindow?
    var weekly: LimitWindow?
    var resetCredits: ResetCredits? = nil
    var updatedAt: Date

    func score(at date: Date) -> Double? {
        guard let session, let weekly else { return nil }
        return min(session.effectiveRemaining(at: date), weekly.effectiveRemaining(at: date))
    }

    func availableAt(from date: Date) -> Date? {
        guard let session, let weekly else { return nil }
        let waits = [session, weekly].compactMap { window -> Date? in
            window.effectiveRemaining(at: date) > 0 ? date : window.resetsAt
        }
        return waits.count == 2 ? waits.max() : nil
    }
}

enum Recommendation: Equatable {
    case switchNow(AccountSnapshot)
    case wait(AccountSnapshot, Date)
    case none
}

enum AccountChooser {
    static func next(accounts: [AccountSnapshot], excluding currentID: String?, now: Date) -> Recommendation {
        let others = accounts.filter { $0.id != currentID }
        if let best = others
            .compactMap({ account in account.score(at: now).map { (account, $0) } })
            .filter({ $0.1 > 0 })
            .max(by: { ($0.1, $0.0.updatedAt) < ($1.1, $1.0.updatedAt) })?.0 {
            return .switchNow(best)
        }
        if let soonest = others
            .compactMap({ account in account.availableAt(from: now).map { (account, $0) } })
            .min(by: { $0.1 < $1.1 }) {
            return .wait(soonest.0, soonest.1)
        }
        return .none
    }
}

struct FetchedUsage {
    var session: LimitWindow?
    var weekly: LimitWindow?
    var resetCredits: ResetCredits?
}

enum CodexUsageError: LocalizedError {
    case notLoggedIn
    case apiKeyLogin
    case invalidAuth
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "No Codex login found. Sign in with the Codex CLI, then refresh."
        case .apiKeyLogin: return "Codex subscription limits require a ChatGPT login, not an API key."
        case .invalidAuth: return "Codex login data could not be read. Sign in again with the Codex CLI."
        case .invalidResponse: return "Codex returned usage data in an unexpected format."
        case .requestFailed(let status): return "Codex usage request failed (HTTP \(status))."
        }
    }
}

struct CodexUsageClient {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    func fetch() async throws -> AccountSnapshot {
        let path = try authPath()
        var auth = try readAuth(path)
        guard var accessToken = token(named: "access_token", in: auth) else {
            if auth["OPENAI_API_KEY"] != nil { throw CodexUsageError.apiKeyLogin }
            throw CodexUsageError.notLoggedIn
        }

        var response = try await requestUsage(token: accessToken, accountID: token(named: "account_id", in: auth))
        if response.1.statusCode == 401 || response.1.statusCode == 403 {
            guard let refreshToken = token(named: "refresh_token", in: auth) else {
                throw CodexUsageError.invalidAuth
            }
            let refreshed = try await refresh(refreshToken)
            guard let newToken = refreshed["access_token"] as? String else { throw CodexUsageError.invalidAuth }
            updateAuth(&auth, with: refreshed)
            try saveAuth(auth, to: path)
            accessToken = newToken
            response = try await requestUsage(token: accessToken, accountID: token(named: "account_id", in: auth))
        }
        guard (200..<300).contains(response.1.statusCode) else {
            throw CodexUsageError.requestFailed(response.1.statusCode)
        }

        var usage = try Self.parseUsage(response.0, response: response.1)
        if let resetResponse = try? await requestResetCredits(
            token: accessToken,
            accountID: token(named: "account_id", in: auth)
        ), (200..<300).contains(resetResponse.1.statusCode),
           let resetCredits = try? Self.parseResetCredits(resetResponse.0) {
            usage.resetCredits = resetCredits
        }
        let claims = Self.jwtPayload(token(named: "id_token", in: auth) ?? accessToken)
        let accountID = token(named: "account_id", in: auth)
            ?? Self.stringClaim("chatgpt_account_id", in: claims)
            ?? Self.stringClaim("sub", in: claims)
        guard let accountID else { throw CodexUsageError.invalidAuth }
        let email = Self.stringClaim("email", in: claims) ?? "Codex account"
        return AccountSnapshot(
            id: accountID.lowercased(), email: email,
            session: usage.session, weekly: usage.weekly,
            resetCredits: usage.resetCredits, updatedAt: Date()
        )
    }

    static func parseUsage(_ data: Data, response: HTTPURLResponse? = nil, now: Date = Date()) throws -> FetchedUsage {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = body["rate_limit"] as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        let primary = candidate(
            rateLimit["primary_window"],
            headerPercent: number(response?.value(forHTTPHeaderField: "x-codex-primary-used-percent")),
            fallback: .session
        )
        let secondary = candidate(
            rateLimit["secondary_window"],
            headerPercent: number(response?.value(forHTTPHeaderField: "x-codex-secondary-used-percent")),
            fallback: .weekly
        )
        let candidates = [primary, secondary].compactMap { $0 }
        return FetchedUsage(
            session: window(.session, from: candidates, now: now),
            weekly: window(.weekly, from: candidates, now: now),
            resetCredits: embeddedResetCredits(in: body)
        )
    }

    static func parseResetCredits(_ data: Data) throws -> ResetCredits {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = number(body["available_count"]), available >= 0 else {
            throw CodexUsageError.invalidResponse
        }
        let expiries = (body["credits"] as? [[String: Any]] ?? [])
            .filter { ($0["status"] as? String).map { $0 == "available" } ?? true }
            .compactMap { isoDate($0["expires_at"] as? String) }
            .sorted()
        return ResetCredits(available: Int(available.rounded(.down)), expiries: expiries)
    }

    private static func embeddedResetCredits(in body: [String: Any]) -> ResetCredits? {
        guard let value = body["rate_limit_reset_credits"] as? [String: Any],
              let available = number(value["available_count"]), available >= 0 else { return nil }
        return ResetCredits(available: Int(available.rounded(.down)), expiries: [])
    }

    private enum Kind { case session, weekly }
    private struct Candidate { var json: [String: Any]; var used: Double?; var fallback: Kind }

    private static func candidate(_ value: Any?, headerPercent: Double?, fallback: Kind) -> Candidate? {
        guard let json = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
        return Candidate(json: json, used: number(json["used_percent"]) ?? headerPercent, fallback: fallback)
    }

    private static func window(_ kind: Kind, from candidates: [Candidate], now: Date) -> LimitWindow? {
        let match = candidates.first { exactKind($0.json) == kind }
            ?? candidates.first { exactKind($0.json) == nil && sameKind($0.fallback, kind) }
        guard let match, let used = match.used else { return nil }
        let reset = number(match.json["reset_at"]).map(Date.init(timeIntervalSince1970:))
            ?? number(match.json["reset_after_seconds"]).map(now.addingTimeInterval)
        return LimitWindow(remaining: 100 - used, resetsAt: reset)
    }

    private static func exactKind(_ json: [String: Any]) -> Kind? {
        guard let seconds = number(json["limit_window_seconds"]) else { return nil }
        if Int(seconds) == 18_000 { return .session }
        if Int(seconds) == 604_800 { return .weekly }
        return nil
    }

    private static func sameKind(_ lhs: Kind, _ rhs: Kind) -> Bool {
        switch (lhs, rhs) { case (.session, .session), (.weekly, .weekly): return true; default: return false }
    }

    private func authPath() throws -> URL {
        let fm = FileManager.default
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            if fm.fileExists(atPath: url.path) { return url }
        }
        for relative in [".config/codex/auth.json", ".codex/auth.json"] {
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent(relative)
            if fm.fileExists(atPath: url.path) { return url }
        }
        throw CodexUsageError.notLoggedIn
    }

    private func readAuth(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CodexUsageError.invalidAuth
        }
        return value
    }

    private func token(named name: String, in auth: [String: Any]) -> String? {
        (auth["tokens"] as? [String: Any])?[name] as? String
    }

    private func requestUsage(token: String, accountID: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLimitBar", forHTTPHeaderField: "User-Agent")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
        return (data, response)
    }

    private func requestResetCredits(token: String, accountID: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.resetCreditsURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLimitBar", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
        return (data, response)
    }

    private func refresh(_ refreshToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidAuth
        }
        return json
    }

    private func updateAuth(_ auth: inout [String: Any], with refreshed: [String: Any]) {
        var tokens = auth["tokens"] as? [String: Any] ?? [:]
        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = refreshed[key] as? String { tokens[key] = value }
        }
        auth["tokens"] = tokens
        auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    }

    private func saveAuth(_ auth: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringClaim(_ key: String, in payload: [String: Any]?) -> String? {
        if let value = payload?[key] as? String { return value }
        for value in payload?.values ?? Dictionary<String, Any>().values {
            if let nested = value as? [String: Any], let found = stringClaim(key, in: nested) { return found }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
