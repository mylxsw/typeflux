import Foundation

/// The signed-in user as `/api/v1/me` returns it. Only fields the mobile account
/// card shows are decoded, so new server fields never break sign-in.
public struct ChatProfile: Decodable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String?
    public var providers: [String]?

    public init(id: String, email: String, name: String? = nil, providers: [String]? = nil) {
        self.id = id; self.email = email; self.name = name; self.providers = providers
    }
}

/// This billing period's credits from `/api/v1/usage/current-period/stats`.
public struct ChatCreditUsage: Decodable, Equatable, Sendable {
    public struct Credits: Decodable, Equatable, Sendable {
        public var limit: Int
        public var used: Int
        public var remaining: Int
        public var unlimited: Bool

        public init(limit: Int, used: Int, remaining: Int, unlimited: Bool = false) {
            self.limit = limit; self.used = used; self.remaining = remaining; self.unlimited = unlimited
        }
    }

    public var periodEnd: Date
    public var planCode: String
    public var paid: Bool
    public var credits: Credits

    public init(periodEnd: Date, planCode: String, paid: Bool, credits: Credits) {
        self.periodEnd = periodEnd; self.planCode = planCode; self.paid = paid; self.credits = credits
    }

    /// The share of this period's credits already used, clamped to 0...1. Unlimited
    /// plans and plans without a limit report nil, so no meter is drawn.
    public var usedFraction: Double? {
        guard !credits.unlimited, credits.limit > 0 else { return nil }
        return min(max(Double(credits.used) / Double(credits.limit), 0), 1)
    }
}

/// Regenerating an answer is a cloud-only turn, like sending: it never advertises
/// or inherits desktop tools.
public struct ChatRegenerateRequest: Encodable, Equatable, Sendable {
    public var messageId: String
    public var deviceId: String
    public var modelRef: String?
    public let tools: [String] = []

    public init(messageId: String, deviceId: String, modelRef: String? = nil) {
        self.messageId = messageId; self.deviceId = deviceId; self.modelRef = modelRef
    }
}

/// Operator-reviewed recipients, including gateways and tool processors.
public struct ChatAIDisclosure: Codable, Equatable, Sendable {
    public let version: String
    public let providers: [String]
    public init(version: String, providers: [String]) {
        self.version = version; self.providers = providers
    }

    public var isValid: Bool {
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !providers.isEmpty &&
            providers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct ChatDeletionProof: Encodable, Sendable {
    public let provider: String
    public let password: String?
    public let idToken: String?
    public let authorizationCode: String?
    public let clientId: String?
    public init(provider: String, password: String? = nil, idToken: String? = nil,
                authorizationCode: String? = nil, clientId: String? = nil) {
        self.provider = provider; self.password = password; self.idToken = idToken
        self.authorizationCode = authorizationCode; self.clientId = clientId
    }
}
