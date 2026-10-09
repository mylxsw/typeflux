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
        var currentToken = accessToken
        if currentToken == nil, isLoggedIn, hasStoredRefreshToken {
            // The access token lapsed (for example while the Mac slept); renew
            // it instead of treating the session as revoked.
            let renewal = await refreshStoredAccessToken(force: true)
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            switch renewal {
            case .refreshed:
                currentToken = accessToken
            case .invalidated:
                logout(clearRecentInputMemory: false)
                logger.error("Profile refresh found a revoked session; cleared it")
                return .unauthenticated
            case .failed, .unavailable:
                logger.error("Profile refresh could not renew the access token; keeping the session")
                return .failed
            }
        }
        guard let token = currentToken else {
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
            if shouldInvalidateSession(for: error) {
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
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        } catch {
            guard generation == sessionGeneration else { return discardStaleProfileRefresh() }
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        }
    }

    private func discardStaleProfileRefresh() -> SessionRefreshResult {
        logger.info("Discarding profile refresh result for a replaced session")
        return .failed
    }
}
