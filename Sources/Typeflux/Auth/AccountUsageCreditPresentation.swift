import Foundation

struct AccountUsageCreditPresentation: Equatable {
    enum Balance: Equatable {
        case unavailable
        case unlimited
        case limited(remaining: Int, limit: Int)
    }

    let credits: CloudCreditSummary?

    var balance: Balance {
        guard let credits else { return .unavailable }
        if credits.unlimited { return .unlimited }
        guard credits.limit >= 0 else { return .unavailable }
        return .limited(remaining: max(0, credits.remaining), limit: credits.limit)
    }

    var remainingFraction: Double? {
        guard case let .limited(remaining, limit) = balance, limit > 0 else { return nil }
        return Double(remaining) / Double(limit)
    }

    var progress: Double? {
        remainingFraction.map { min($0, 1) }
    }

    var isExhausted: Bool {
        guard case let .limited(remaining, limit) = balance else { return false }
        return limit > 0 && remaining == 0
    }
}
