import Foundation

@MainActor
extension AuthState {
    // MARK: - Session Restore

    func restoreSession() {
        let storedToken = loadStoredToken()
        cachedStoredToken = storedToken
        cachedRefreshToken = loadStoredRefreshToken()
        let hasValidAccessToken = accessToken != nil
        let hasRefreshToken = hasStoredRefreshToken
        logger.info(
            "Session restore: storedAccessToken=\(storedToken != nil, privacy: .public), validAccessToken=\(hasValidAccessToken, privacy: .public), storedRefreshToken=\(hasRefreshToken, privacy: .public)"
        )
        if hasValidAccessToken {
            userProfile = loadStoredUserProfile()
            isLoggedIn = true
            Task { await refreshProfile() }
            Task { await refreshTokenIfNeeded() }
        } else if hasRefreshToken {
            userProfile = loadStoredUserProfile()
            isLoggedIn = true
            let generation = sessionGeneration
            Task {
                let result = await refreshStoredAccessToken(force: true)
                // A login or logout while restoring owns the session now.
                guard generation == sessionGeneration else { return }
                switch result {
                case .refreshed:
                    await refreshProfile()
                case .invalidated:
                    logout(clearRecentInputMemory: false)
                case .failed, .unavailable:
                    logger.error("Session restore could not refresh access token")
                }
            }
        }
        startRefreshTimer()
    }

    // MARK: - Background Timer

    /// Schedules the next background refresh check for when the current
    /// access token enters its refresh lead time, bounded by
    /// `minimumTimerInterval` and `timerInterval`. Short-lived access tokens
    /// (the API defaults to 15 minutes) are therefore renewed before they
    /// lapse instead of on a fixed hourly cadence.
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        let delay = nextRefreshCheckDelay()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await refreshTokenIfNeeded()
                startRefreshTimer()
            }
        }
    }

    func nextRefreshCheckDelay(now: Date = Date()) -> TimeInterval {
        guard let expiresAt = accessTokenExpiresAt else { return Self.timerInterval }
        let leadTime = accessTokenRefreshLeadTime()
        let dueIn = TimeInterval(expiresAt) - leadTime - now.timeIntervalSince1970
        return min(Self.timerInterval, max(Self.minimumTimerInterval, dueIn))
    }

    // MARK: - Token Helpers

    func shouldInvalidateSession(for error: AuthError) -> Bool {
        switch error {
        case .unauthorized:
            true
        case let .serverError(code, _):
            code == "USER_NOT_FOUND"
                || code == "AUTH_REFRESH_TOKEN_INVALID"
                || code == "AUTH_REFRESH_TOKEN_REUSED"
        case .networkError, .invalidResponse:
            false
        }
    }

    var hasStoredRefreshToken: Bool {
        guard let refreshToken = cachedRefreshToken else { return false }
        return !refreshToken.isEmpty
    }

    func refreshStoredAccessToken(force: Bool) async -> AccessTokenRefreshResult {
        if !force, !isAccessTokenExpiringSoon() {
            return .unavailable
        }
        if let accessTokenRefreshTask {
            return await accessTokenRefreshTask.value
        }

        guard let refreshToken = cachedRefreshToken, !refreshToken.isEmpty else {
            logger.debug("Access token refresh needed but no refresh token is stored")
            return .unavailable
        }

        let generation = sessionGeneration
        let task = Task { @MainActor [weak self] () -> AccessTokenRefreshResult in
            guard let self else { return .unavailable }
            return await performAccessTokenRefresh(refreshToken: refreshToken, generation: generation)
        }
        accessTokenRefreshTask = task
        let result = await task.value
        if generation == sessionGeneration {
            accessTokenRefreshTask = nil
        }
        return result
    }

    private func performAccessTokenRefresh(
        refreshToken: String,
        generation: Int
    ) async -> AccessTokenRefreshResult {
        logger.info("Refreshing access token...")
        do {
            let response = try await refreshAccessToken(refreshToken)
            guard generation == sessionGeneration else {
                // Logout or a new login happened meanwhile; never resurrect
                // the old session with the returned pair.
                logger.info("Discarding token refresh result for a replaced session")
                return .unavailable
            }
            let normalizedExpiresAt = normalizeLoginExpiry(response.expiresAt)
            saveStoredSession(
                response.accessToken,
                normalizedExpiresAt,
                response.refreshToken ?? refreshToken
            )
            inMemorySessionToken = (response.accessToken, normalizedExpiresAt)
            cachedStoredToken = (response.accessToken, normalizedExpiresAt)
            cachedRefreshToken = response.refreshToken ?? refreshToken
            logger.info("Token refreshed successfully")
            NotificationCenter.default.post(name: .authTokenDidRefresh, object: self)
            return .refreshed
        } catch let error as AuthError {
            logger.error("Token refresh failed: \(error.localizedDescription)")
            guard generation == sessionGeneration else { return .unavailable }
            return shouldInvalidateSession(for: error) ? .invalidated : .failed
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Expiry of the token returned by `accessToken`, or of the stored token
    /// when it has already lapsed.
    var accessTokenExpiresAt: Int? {
        let now = Int(Date().timeIntervalSince1970)
        if let inMemorySessionToken, inMemorySessionToken.expiresAt > now {
            return inMemorySessionToken.expiresAt
        }
        return cachedStoredToken?.expiresAt
    }

    func isAccessTokenExpiringSoon() -> Bool {
        guard let expiresAt = accessTokenExpiresAt else { return true }
        let threshold = Date().timeIntervalSince1970 + accessTokenRefreshLeadTime()
        return TimeInterval(expiresAt) < threshold
    }

    /// How long before expiry the current access token should be refreshed:
    /// one third of its signed lifetime, at least one minute and at most
    /// `refreshEarlyInterval`. Tokens whose lifetime cannot be read keep the
    /// `refreshEarlyInterval` policy.
    func accessTokenRefreshLeadTime() -> TimeInterval {
        let token = inMemorySessionToken?.token ?? cachedStoredToken?.token
        guard let token, let lifetime = AccessTokenClaims.lifetime(of: token) else {
            return Self.refreshEarlyInterval
        }
        return min(Self.refreshEarlyInterval, max(Self.minimumTimerInterval, lifetime / 3))
    }

    func normalizeLoginExpiry(_ expiresAt: Int) -> Int {
        let now = Int(Date().timeIntervalSince1970)
        // Accept common server variants: Unix milliseconds and expires-in seconds.
        if expiresAt > 10_000_000_000 {
            return expiresAt / 1000
        }
        if expiresAt > now {
            return expiresAt
        }
        if expiresAt > 0, expiresAt <= 31_536_000 {
            return now + expiresAt
        }
        return expiresAt
    }
}
