import AppKit
import AuthenticationServices
import Foundation
import os

/// Handles Sign In with Apple using ASAuthorizationAppleIDProvider.
///
/// Flow:
/// 1. Creates an Apple ID authorization request with email and full name scopes.
/// 2. Presents the native Sign In with Apple sheet via ASAuthorizationController.
/// 3. Extracts the identity token (JWT) from ASAuthorizationAppleIDCredential.
/// 4. Returns the ID token for verification by the Typeflux backend.
///
/// Requirements:
/// - The app target must have the "Sign In with Apple" capability enabled in Xcode.
/// - The app bundle ID must be registered as a native app in the Apple Developer Console.
/// - The backend APPLE_OIDC_CLIENT_ID must match the bundle ID (or configured Services ID).
@MainActor
final class AppleSignInService: NSObject {
    private static let logger = Logger(subsystem: "dev.typeflux", category: "AppleSignInService")
    private static let shared = AppleSignInService()

    private var continuation: CheckedContinuation<String, Error>?

    /// Initiates the Sign In with Apple flow and returns the Apple ID token on success.
    static func signIn() async throws -> String {
        try await shared.performSignIn()
    }

    private func performSignIn() async throws -> String {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: AppleSignInError.internalError)
                return
            }
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: AppleSignInError.missingIDToken)
            continuation = nil
            return
        }
        AppleSignInService.logger.debug(
            "[Apple Sign In] received identity token (first 20 chars): \(String(idToken.prefix(20)), privacy: .public)..."
        )
        continuation?.resume(returning: idToken)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        AppleSignInService.logger.error("[Apple Sign In] error: \(error.localizedDescription, privacy: .public)")
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Errors

enum AppleSignInError: LocalizedError {
    case missingIDToken
    case internalError

    var errorDescription: String? {
        switch self {
        case .missingIDToken:
            "Failed to retrieve Apple ID token."
        case .internalError:
            "An internal error occurred during Apple Sign In."
        }
    }
}
