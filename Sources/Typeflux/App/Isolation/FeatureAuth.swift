import Foundation

/// Access credentials travel only over private authenticated feature channels.
/// Refresh credentials and Keychain mutations belong exclusively to the host.
struct FeatureAuth: Codable, Sendable {
    let generation: Int
    let token: String?
    let expiresAt: Int?
    let profile: UserProfile?
    let subscription: BillingSubscriptionSnapshot

    @MainActor static func capture() -> Self {
        let state = AuthState.shared
        return .init(generation: state.sessionGeneration, token: state.accessToken,
            expiresAt: state.accessTokenExpiresAt, profile: state.userProfile, subscription: state.subscription)
    }

    /// A reconnected channel may still be draining cancelled work. Bootstrap is
    /// read-only, so retry transient admission failures without poisoning the UI.
    static func bootstrapAfterReconnect(_ peer: FeatureRPC, initialDelay: Duration = .milliseconds(100),
                                        maximumDelay: Duration = .seconds(5)) async throws -> Self {
        var delay = initialDelay
        while true {
            try Task.checkCancellation()
            do { return try await peer.call("bootstrap", FeatureRPC.Empty()) }
            catch FeatureRPC.Failure.busy {}
            catch FeatureRPC.Failure.unavailable {}
            catch FeatureRPC.Failure.timedOut {}
            try await Task.sleep(for: delay)
            delay = min(delay * 2, maximumDelay)
        }
    }

    @MainActor func apply() {
        guard FeatureProcess.role != .host else { return }
        let state = AuthState.shared
        guard generation >= state.sessionGeneration else { return }
        let previous = state.userProfile?.id
        let changedSession = generation != state.sessionGeneration
        state.sessionGeneration = generation
        state.inMemorySessionToken = token.flatMap { value in expiresAt.map { (value, $0) } }
        state.cachedStoredToken = state.inMemorySessionToken
        state.cachedRefreshToken = nil
        state.userProfile = profile
        state.isLoggedIn = profile != nil && token != nil
        state.subscription = subscription
        if changedSession || previous != profile?.id {
            NotificationCenter.default.post(name: .authDidLogout, object: state)
            if profile != nil { NotificationCenter.default.post(name: .authDidLogin, object: state) }
        }
        NotificationCenter.default.post(name: .authTokenDidRefresh, object: state)
        NotificationCenter.default.post(name: .authSubscriptionDidChange, object: state)
    }

    @MainActor static func refresh(action: String = "refreshAuth") async -> Bool {
        do {
            let data = try await FeatureProcess.route(.init(destination: .host, action: action, payload: JSONEncoder().encode(AuthState.shared.sessionGeneration)))
            try JSONDecoder().decode(Self.self, from: data).apply()
            return true
        } catch { return false }
    }

    /// A missed auth notification must not make reads fail for the lifetime of
    /// a window. Bootstrap uses the existing private channel, never credentials
    /// from a file or another process. It cannot switch the visible account.
    @MainActor static func synchronizeCacheRead(connection: FeatureRPC, owner: String) async -> Bool {
        guard FeatureProcess.enabled else { return false }
        do {
            let snapshot: Self = try await connection.call("bootstrap", FeatureRPC.Empty())
            let state = AuthState.shared
            guard snapshot.permitsCacheReadRefresh(owner: owner, currentOwner: state.userProfile?.id,
                generation: state.sessionGeneration) else { return false }
            snapshot.apply()
            return true
        } catch {
            AskFailureDiagnostics.shared.record(.cacheAuthorization, error: error)
            return false
        }
    }

    func permitsCacheReadRefresh(owner: String, currentOwner: String?, generation currentGeneration: Int) -> Bool {
        generation >= currentGeneration && currentOwner == profile?.id && (owner == "local" || owner == profile?.id)
    }
}
