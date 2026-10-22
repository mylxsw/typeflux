import Foundation

struct FeatureModuleRecovery: Codable, Sendable {
    let id: ModuleID
    let reset: Bool
}

/// Settings observes and repairs the owning processes, not unused local services.
struct FeatureModuleHealth: Sendable {
    var route: @MainActor @Sendable (FeatureCommand) async throws -> Data = { try await FeatureProcess.route($0) }

    func snapshots() async throws -> [ModuleID: ModuleHealth] {
        let data = try await route(.init(destination: .host, action: "moduleHealth"))
        let roles = try JSONDecoder().decode([FeatureRole: [ModuleID: ModuleHealth]].self, from: data)
        var result: [ModuleID: ModuleHealth] = [:]
        for values in roles.values {
            for (id, health) in values {
                if result[id].map({ Self.priority($0) >= Self.priority(health) }) != true { result[id] = health }
            }
        }
        return result
    }

    func recover(_ id: ModuleID, reset: Bool) async -> ModuleRecoveryResponse {
        do {
            let data = try await route(.init(destination: .host, action: "recoverModules",
                payload: JSONEncoder().encode(FeatureModuleRecovery(id: id, reset: reset))))
            return try JSONDecoder().decode(ModuleRecoveryResponse.self, from: data)
        } catch { return .unavailable }
    }

    private static func priority(_ health: ModuleHealth) -> Int {
        if health.failure != nil { return health.activeOperations > 0 || health.hasLifecycleWork ? 10 : 9 }
        switch health.state {
        case .degraded: return 8
        case .circuitOpen, .recovering: return 7
        case .starting: return 6
        case .ready: return 5
        case .stopped, .disabled: return 0
        }
    }
}
