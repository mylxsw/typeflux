import Foundation

struct AskBudgetResources: Codable, Equatable, Sendable {
    var tokens: Int64 = 0
    var microcredits: Int64 = 0
    var webRequests: Int64 = 0
    var children: Int64 = 0
    var operations: Int64 = 0

    static let standard = Self(
        tokens: 500_000,
        microcredits: 100_000_000,
        webRequests: 16,
        children: 4,
        operations: 128
    )
    var valid: Bool {
        [tokens, microcredits, webRequests, children, operations].allSatisfy { (0 ... (1 << 50)).contains($0) }
    }

    func adding(_ other: Self) -> Self {
        .init(tokens: tokens + other.tokens, microcredits: microcredits + other.microcredits,
              webRequests: webRequests + other.webRequests, children: children + other.children,
              operations: operations + other.operations)
    }

    func exceeds(_ limit: Self) -> String? {
        for (name, value, maximum) in [("tokens", tokens, limit.tokens), (
            "cost_estimate",
            microcredits,
            limit.microcredits
        ),
        ("web_requests", webRequests, limit.webRequests), (
            "children",
            children,
            limit.children
        ),
        ("operations", operations, limit.operations)]
            where value > maximum {
            return name
        }
        return nil
    }
}

/// Persisted at dispatch, independently of receipt fields and Memory source ownership.
struct AskBudgetInvocationIdentity: Codable, Equatable, Sendable {
    var owner: String
    var conversationId: String
    var rootId: String
    var runId: String
    var deviceId: String
}

struct AskBudgetReservation: Codable, Equatable, Sendable {
    var runId: String?
    var identity: AskBudgetInvocationIdentity?
    var operationId: String
    var stepId: String
    var callId: String
    var kind: String
    var reserved: AskBudgetResources
    var actual: AskBudgetResources = .init()
    var state = "reserved"
    var source = "unknown"
    var tokensFinal = false
    var costFinal = false

    var occupied: AskBudgetResources {
        guard state != "released" else { return .init() }
        return .init(tokens: tokensFinal ? actual.tokens : max(actual.tokens, reserved.tokens),
                     microcredits: costFinal ? actual.microcredits : max(actual.microcredits, reserved.microcredits),
                     webRequests: max(actual.webRequests, reserved.webRequests), children: max(
                         actual.children,
                         reserved.children
                     ),
                     operations: max(actual.operations, reserved.operations))
    }
}

struct AskBudgetEvent: Codable, Equatable, Sendable {
    var runId: String
    var stepId: String
    var callId: String
    var operationId: String
    var kind: String
    var state: String
    var source: String
}

struct AskBudgetSummary: Codable, Equatable, Sendable {
    var version: Int64
    var limits: AskBudgetResources
    var occupied: AskBudgetResources
    var actual: AskBudgetResources
    var pending: Int
    var deadline: Date
    var stopReason: String?
    var metering: String
    var events: [AskBudgetEvent]?
}

enum AskBudgetError: Error, Equatable { case reached(String), replay, invalid, missing }

/// The R03 journal is independent from conversation content. Restarting keeps all
/// pending reservations; only a reservation that never started may be released.
struct AskBudgetController: Codable, Equatable, Sendable {
    var version = 1
    var revision: Int64 = 1
    var runId: String
    var limits: AskBudgetResources
    var deadline: Date
    var stopReason: String?
    var reservations: [String: AskBudgetReservation] = [:]

    var valid: Bool {
        version == 1 && revision > 0 && limits.valid && reservations.count <= 4096
            && reservations
            .allSatisfy { $0.key == $0.value.operationId && $0.value.reserved.valid && $0.value.actual.valid
                && ["reserved", "pending", "settled", "released"].contains($0.value.state)
            }
    }

    var occupied: AskBudgetResources {
        reservations.values.reduce(.init()) { $0.adding($1.occupied) }
    }

    var summary: AskBudgetSummary {
        .init(version: revision, limits: limits, occupied: occupied,
              actual: reservations.values.reduce(.init()) { $0.adding($1.actual) },
              pending: reservations.values.filter { ["reserved", "pending"].contains($0.state) }.count,
              deadline: deadline, stopReason: stopReason,
              metering: reservations.values.contains { $0.source == "client" } ? "client_reported" : "estimated",
              events: reservations.values.sorted { $0.operationId < $1.operationId }.map {
                  .init(runId: $0.runId ?? runId, stepId: $0.stepId, callId: $0.callId, operationId: $0.operationId,
                        kind: $0.kind, state: $0.state, source: $0.source)
              })
    }

    mutating func reserve(_ proposed: AskBudgetReservation, at now: Date) throws {
        guard valid, !proposed.operationId.isEmpty, proposed.reserved.valid else { throw AskBudgetError.invalid }
        if let old = reservations[proposed.operationId] {
            guard old.runId == proposed.runId, old.identity == proposed.identity,
                  old.reserved == proposed.reserved, old.kind == proposed.kind, old.callId == proposed.callId,
                  old.stepId == proposed.stepId else { throw AskBudgetError.invalid }
            guard old.state == "reserved" else { throw AskBudgetError.replay }
            return
        }
        let reason = stopReason ?? (now >= deadline ? "duration" : occupied.adding(proposed.reserved).exceeds(limits))
        if let reason {
            stopReason = reason
            revision += 1
            throw AskBudgetError.reached(reason)
        }
        guard reservations.count < 4096 else { throw AskBudgetError.invalid }
        var value = proposed
        value.actual = .init()
        value.state = "reserved"
        value.source = "unknown"
        value.tokensFinal = false
        value.costFinal = false
        reservations[value.operationId] = value
        revision += 1
    }

    mutating func start(_ id: String, at now: Date) throws {
        guard var value = reservations[id] else { throw AskBudgetError.missing }
        guard value.state == "reserved" else { throw AskBudgetError.replay }
        guard now < deadline else { stopReason = "duration"
            revision += 1
            throw AskBudgetError.reached("duration")
        }
        value.state = "pending"
        value.actual.webRequests = value.reserved.webRequests
        value.actual.children = value.reserved.children
        value.actual.operations = value.reserved.operations
        reservations[id] = value
        revision += 1
    }

    mutating func release(_ id: String) throws {
        guard var value = reservations[id] else { throw AskBudgetError.missing }
        if value.state == "released" {
            return
        }
        guard value.state == "reserved" else { throw AskBudgetError.replay }
        value.state = "released"
        reservations[id] = value
        revision += 1
    }

    mutating func settle(
        _ id: String,
        actual: AskBudgetResources,
        source: String,
        tokensFinal: Bool,
        costFinal: Bool
    ) throws {
        guard actual.valid else { throw AskBudgetError.invalid }
        guard var value = reservations[id] else { throw AskBudgetError.missing }
        guard ["pending", "settled"].contains(value.state) else { throw AskBudgetError.invalid }
        let before = value
        value.actual.tokens = max(value.actual.tokens, actual.tokens)
        value.actual.microcredits = max(value.actual.microcredits, actual.microcredits)
        if ["provider", "scheduler"].contains(source) {
            value.tokensFinal = value.tokensFinal || tokensFinal
            value.costFinal = value.costFinal || costFinal
        }
        if value.source != "provider" {
            value.source = source
        }
        if value.tokensFinal, value.costFinal {
            value.state = "settled"
        }
        guard value != before else { return }
        reservations[id] = value
        revision += 1
        if let reason = occupied.exceeds(limits) {
            stopReason = reason
        }
    }
}
