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
            Task {
                switch await refreshStoredAccessToken(force: true) {
                case .refreshed:
                    await refreshProfile()
                case .invalidated:
                    logout()
                case .failed, .unavailable:
                    logger.error("Session restore could not refresh access token")
                }
            }
        }
        startRefreshTimer()
    }

    // MARK: - Background Timer

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshTokenIfNeeded()
            }
        }
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

        guard let refreshToken = cachedRefreshToken, !refreshToken.isEmpty else {
            logger.debug("Access token refresh needed but no refresh token is stored")
            return .unavailable
        }

        logger.info("Refreshing access token...")
        do {
            let response = try await refreshAccessToken(refreshToken)
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
            return shouldInvalidateSession(for: error) ? .invalidated : .failed
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
            return .failed
        }
    }

    func isAccessTokenExpiringSoon() -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        let threshold = Int(Date().timeIntervalSince1970 + Self.refreshEarlyInterval)
        if let inMemorySessionToken, inMemorySessionToken.expiresAt > now {
            return inMemorySessionToken.expiresAt < threshold
        }
        guard let stored = cachedStoredToken else { return true }
        return stored.expiresAt < threshold
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
