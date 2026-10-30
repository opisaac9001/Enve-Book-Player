import Foundation
import CryptoKit

nonisolated struct HardcoverRequestBudget {
    var nextRequest = Date.distantPast
    var blockedUntil = Date.distantPast
    var interval: TimeInterval = 1

    mutating func observe(status: Int, headers: [String: String], now: Date) {
        let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        if let policy = headers["ratelimit-policy"] {
            for bucket in policy.split(separator: ",") where !bucket.contains("daily") {
                let fields = Self.fields(String(bucket))
                if let quota = fields["q"], let window = fields["w"], quota > 0, window > 0 {
                    interval = max(1, window / quota)
                }
            }
        }
        if let limits = headers["ratelimit"] {
            for bucket in limits.split(separator: ",") {
                let fields = Self.fields(String(bucket))
                if fields["r"] == 0, let delay = fields["t"], delay.isFinite {
                    blockedUntil = max(blockedUntil, now.addingTimeInterval(max(0, delay)))
                }
            }
        }
        for prefix in ["x-ratelimit", "x-ratelimit-daily"] {
            if headers[prefix + "-remaining"].flatMap(Double.init) == 0 {
                let reset = headers[prefix + "-reset"].flatMap(Double.init)
                blockedUntil = max(blockedUntil, reset.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? now.addingTimeInterval(60))
            }
        }
        if status == 429 {
            blockedUntil = max(blockedUntil, Self.retryDate(headers["retry-after"], now: now))
        }
    }

    static func retryDate(_ value: String?, now: Date) -> Date {
        if let seconds = value.flatMap(Double.init), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date(from:)).map { max(now, $0) } ?? now.addingTimeInterval(60)
    }

    private static func fields(_ value: String) -> [String: Double] {
        Dictionary(value.split(separator: ";").compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let number = Double(pair[1]), number.isFinite else { return nil }
            return (pair[0], number)
        }, uniquingKeysWith: { _, last in last })
    }
}

@MainActor
final class HardcoverRequestPacer {
    static let shared = HardcoverRequestPacer()
    private var budgets: [String: HardcoverRequestBudget] = [:]
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void

    init(minimumInterval: TimeInterval = 1, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.sleep = sleep
    }

    nonisolated static func accountKey(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func acquire(account: String, cost: Int, isCurrent: () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            var budget = budgets[account] ?? HardcoverRequestBudget(interval: minimumInterval)
            let current = now()
            if budget.blockedUntil.timeIntervalSince(current) > 30 {
                throw HardcoverError.rateLimited(until: budget.blockedUntil)
            }
            let wait = max(budget.nextRequest, budget.blockedUntil).timeIntervalSince(current)
            if wait > 0 {
                try await sleep(wait)
                continue
            }
            budget.nextRequest = current.addingTimeInterval(budget.interval * Double(max(1, cost)))
            budgets[account] = budget
            return
        }
    }

    func observe(_ response: HTTPURLResponse, account: String) {
        var budget = budgets[account] ?? HardcoverRequestBudget(interval: minimumInterval)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        budget.observe(status: response.statusCode, headers: headers, now: now())
        budgets[account] = budget
    }

    nonisolated static func requestCost(_ query: String) -> Int {
        let pattern = #"\"(?:\\.|[^\"\\])*\"|#[^\n]*|[_A-Za-z][_0-9A-Za-z]*|[{}():@]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let tokens = regex.matches(in: query, range: NSRange(query.startIndex..., in: query)).compactMap {
            Range($0.range, in: query).map { String(query[$0]) }
        }
        var depth = 0, parentheses = 0, fields = 0
        var skipName = false
        for token in tokens {
            if token.hasPrefix("\"") || token.hasPrefix("#") { continue }
            if token == "(" { parentheses += 1; continue }
            if token == ")" { parentheses -= 1; continue }
            if parentheses > 0 { continue }
            if token == "{" { depth += 1; continue }
            if token == "}" { depth -= 1; continue }
            guard depth == 1 else { continue }
            if token == ":" || token == "@" { skipName = true; continue }
            if skipName { skipName = false }
            else { fields += 1 }
        }
        return max(1, fields)
    }
}
