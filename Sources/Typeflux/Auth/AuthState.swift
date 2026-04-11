import Foundation
import os

/// Observable auth state manager, shared across the app.
@MainActor
final class AuthState: ObservableObject {
    static let shared = AuthState()

    private let logger = Logger(subsystem: "dev.typeflux", category: "AuthState")

    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var userProfile: UserProfile?
    @Published private(set) var isLoading: Bool = false

    /// Refresh the access token when it expires within this window (7 days).
    private static let refreshEarlyInterval: TimeInterval = 7 * 24 * 3600

    /// Background timer interval: check every hour.
    private static let timerInterval: TimeInterval = 3600

    private var refreshTimer: Timer?

    var accessToken: String? {
        guard let stored = KeychainTokenStore.loadToken(),
              stored.expiresAt > Int(Date().timeIntervalSince1970)
        else {
            return nil
        }
        return stored.token
    }

    private init() {
        restoreSession()
    }

    // MARK: - Session Restore

    private func restoreSession() {
        if KeychainTokenStore.isTokenValid {
            userProfile = KeychainTokenStore.loadUserProfile()
            isLoggedIn = true
            Task { await refreshProfile() }
            Task { await refreshTokenIfNeeded() }
        }
        startRefreshTimer()
    }

    // MARK: - Login

    func handleLoginSuccess(token: String, expiresAt: Int, refreshToken: String? = nil) async {
        KeychainTokenStore.saveToken(token, expiresAt: expiresAt, refreshToken: refreshToken)
        isLoggedIn = true
        await refreshProfile()
    }

    // MARK: - Logout

    func logout() {
        if let refreshToken = KeychainTokenStore.loadRefreshToken() {
            Task {
                try? await AuthAPIService.logout(refreshToken: refreshToken)
            }
        }
        KeychainTokenStore.clearAll()
        isLoggedIn = false
        userProfile = nil
        logger.info("User logged out")
    }

    // MARK: - Token Refresh

    /// Refreshes the access token when it will expire within 7 days.
    /// Safe to call from multiple trigger points; skips silently when not needed.
    func refreshTokenIfNeeded() async {
        guard isLoggedIn else { return }
        guard KeychainTokenStore.isTokenExpiringSoon(within: Self.refreshEarlyInterval) else { return }

        guard let refreshToken = KeychainTokenStore.loadRefreshToken(), !refreshToken.isEmpty else {
            logger.debug("Token expiring soon but no refresh token stored")
            return
        }

        logger.info("Access token expiring soon, refreshing...")
        do {
            let response = try await AuthAPIService.refreshToken(refreshToken)
            KeychainTokenStore.saveToken(
                response.accessToken,
                expiresAt: response.expiresAt,
                refreshToken: response.refreshToken
            )
            logger.info("Token refreshed successfully")
        } catch let error as AuthError {
            logger.error("Token refresh failed: \(error.localizedDescription)")
            if shouldInvalidateSession(for: error) {
                logout()
            }
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Refresh

    func refreshProfile() async {
        guard let token = accessToken else {
            logout()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let profile = try await AuthAPIService.fetchProfile(token: token)
            userProfile = profile
            KeychainTokenStore.saveUserProfile(profile)
            logger.info("Profile refreshed for \(profile.email)")
        } catch let error as AuthError {
            if shouldInvalidateSession(for: error) {
                logout()
            }
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
        } catch {
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Timer

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshTokenIfNeeded()
            }
        }
    }

    // MARK: - Helpers

    private func shouldInvalidateSession(for error: AuthError) -> Bool {
        switch error {
        case .unauthorized:
            true
        case .serverError(let code, _):
            code == "USER_NOT_FOUND"
                || code == "AUTH_REFRESH_TOKEN_INVALID"
                || code == "AUTH_REFRESH_TOKEN_REUSED"
        case .networkError, .invalidResponse:
            false
        }
    }
}
