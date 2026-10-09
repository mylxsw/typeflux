import Foundation

@MainActor
extension AuthState {
    // MARK: - Profile Refresh

    func refreshProfileIfNeeded() {
        guard isLoggedIn || accessToken != nil else { return }
        Task { await refreshProfile() }
    }

    @discardableResult
    func refreshProfile() async -> SessionRefreshResult {
        await refreshProfile(allowTokenRefresh: true)
    }

    /// Fetches the profile for the session that is current when the call
    /// starts. Every result is checked against that session after each
    /// suspension: a response that arrives after logout or a new login is
    /// dropped (`.failed`) instead of overwriting or logging out the newer
    /// session.
    @discardableResult
    private func refreshProfile(allowTokenRefresh: Bool) async -> SessionRefreshResult {
        let generation = sessionGeneration
        if accessToken == nil, isLoggedIn, hasStoredRefreshToken,
           let outcome = await renewLapsedAccessToken(generation: generation) {
            return outcome
        }
        guard let token = accessToken else {
            logger.error("Profile refresh found no valid access token; clearing session")
            logout(clearRecentInputMemory: false)
            return .unauthenticated
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let profile = try await fetchProfile(token)
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            userProfile = profile
            saveStoredUserProfile(profile)
            logger.info("Profile refreshed for \(profile.email)")
            await refreshSubscription()
            return .authenticated
        } catch let error as AuthError {
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            return await recoverFromProfileError(error, allowTokenRefresh: allowTokenRefresh, generation: generation)
        } catch {
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Handles a profile request rejected by the server: an unauthorized
    /// response gets one token refresh and retry before the session is
    /// cleared; other errors keep the session.
    private func recoverFromProfileError(
        _ error: AuthError,
        allowTokenRefresh: Bool,
        generation: Int
    ) async -> SessionRefreshResult {
        guard shouldInvalidateSession(for: error) else {
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        }
        if allowTokenRefresh {
            let refreshResult = await refreshStoredAccessToken(force: true)
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            switch refreshResult {
            case .refreshed:
                return await refreshProfile(allowTokenRefresh: false)
            case .failed:
                logger.error("Profile refresh could not refresh access token: \(error.localizedDescription)")
                return .failed
            case .invalidated, .unavailable:
                break
            }
        }
        logout(clearRecentInputMemory: false)
        logger.error("Profile refresh invalidated session: \(error.localizedDescription)")
        return .unauthenticated
    }

    /// Renews an access token that lapsed (for example while the Mac slept)
    /// instead of treating the session as revoked. Returns the refresh result
    /// when the profile cannot be fetched, or nil to continue with the new
    /// token.
    private func renewLapsedAccessToken(generation: Int) async -> SessionRefreshResult? {
        let renewal = await refreshStoredAccessToken(force: true)
        guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
        switch renewal {
        case .refreshed:
            return nil
        case .invalidated:
            logout(clearRecentInputMemory: false)
            logger.error("Profile refresh found a revoked session; cleared it")
            return .unauthenticated
        case .failed, .unavailable:
            logger.error("Profile refresh could not renew the access token; keeping the session")
            return .failed
        }
    }

    private func discardStaleProfileRefresh() -> SessionRefreshResult {
        logger.info("Discarding profile refresh result for a replaced session")
        return .failed
    }
}
