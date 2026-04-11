import Foundation
import os

/// Observable auth state manager, shared across the app.
@MainActor
final class AuthState: ObservableObject {
    enum SessionRefreshResult: Equatable {
        case authenticated
        case unauthenticated
        case failed
    }

    static let shared = AuthState()

    private let logger = Logger(subsystem: "dev.typeflux", category: "AuthState")
    private let loadStoredToken: () -> (token: String, expiresAt: Int)?
    private let loadStoredUserProfile: () -> UserProfile?
    private let saveStoredToken: (String, Int) -> Void
    private let saveStoredUserProfile: (UserProfile) -> Void
    private let clearStoredSession: () -> Void
    private let fetchProfile: (String) async throws -> UserProfile

    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var userProfile: UserProfile?
    @Published private(set) var isLoading: Bool = false

    var accessToken: String? {
        guard let stored = loadStoredToken(),
              stored.expiresAt > Int(Date().timeIntervalSince1970)
        else {
            return nil
        }
        return stored.token
    }

    init(
        loadStoredToken: @escaping () -> (token: String, expiresAt: Int)? = {
            KeychainTokenStore.loadToken()
        },
        loadStoredUserProfile: @escaping () -> UserProfile? = {
            KeychainTokenStore.loadUserProfile()
        },
        saveStoredToken: @escaping (String, Int) -> Void = { token, expiresAt in
            KeychainTokenStore.saveToken(token, expiresAt: expiresAt)
        },
        saveStoredUserProfile: @escaping (UserProfile) -> Void = { profile in
            KeychainTokenStore.saveUserProfile(profile)
        },
        clearStoredSession: @escaping () -> Void = {
            KeychainTokenStore.clearAll()
        },
        fetchProfile: @escaping (String) async throws -> UserProfile = { token in
            try await AuthAPIService.fetchProfile(token: token)
        },
    ) {
        self.loadStoredToken = loadStoredToken
        self.loadStoredUserProfile = loadStoredUserProfile
        self.saveStoredToken = saveStoredToken
        self.saveStoredUserProfile = saveStoredUserProfile
        self.clearStoredSession = clearStoredSession
        self.fetchProfile = fetchProfile
        restoreSession()
    }

    // MARK: - Session Restore

    private func restoreSession() {
        if accessToken != nil {
            userProfile = loadStoredUserProfile()
            isLoggedIn = true
            Task { await refreshProfile() }
        }
    }

    // MARK: - Login

    func handleLoginSuccess(token: String, expiresAt: Int) async {
        saveStoredToken(token, expiresAt)
        isLoggedIn = true
        await refreshProfile()
    }

    // MARK: - Logout

    func logout() {
        clearStoredSession()
        isLoggedIn = false
        userProfile = nil
        logger.info("User logged out")
    }

    // MARK: - Profile Refresh

    func refreshProfileIfNeeded() {
        guard isLoggedIn || accessToken != nil else { return }
        Task { await refreshProfile() }
    }

    @discardableResult
    func refreshProfile() async -> SessionRefreshResult {
        guard let token = accessToken else {
            logout()
            return .unauthenticated
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let profile = try await fetchProfile(token)
            userProfile = profile
            saveStoredUserProfile(profile)
            logger.info("Profile refreshed for \(profile.email)")
            return .authenticated
        } catch let error as AuthError {
            if shouldInvalidateSession(for: error) {
                logout()
                logger.error("Profile refresh invalidated session: \(error.localizedDescription)")
                return .unauthenticated
            }
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        } catch {
            logger.error("Failed to refresh profile: \(error.localizedDescription)")
            return .failed
        }
    }

    private func shouldInvalidateSession(for error: AuthError) -> Bool {
        switch error {
        case .unauthorized:
            true
        case .serverError(let code, _):
            code == "USER_NOT_FOUND"
        case .networkError, .invalidResponse:
            false
        }
    }
}
