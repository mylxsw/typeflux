import AppKit
import AuthenticationServices
import Foundation
import Security
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
    nonisolated private static let logger = Logger(subsystem: "dev.typeflux", category: "AppleSignInService")
    private static let shared = AppleSignInService()

    private var continuation: CheckedContinuation<String, Error>?

    /// Initiates the Sign In with Apple flow and returns the Apple ID token on success.
    static func signIn() async throws -> String {
        try await shared.performSignIn()
    }

    private func performSignIn() async throws -> String {
        if
            let runtimeConfiguration = Self.currentRuntimeConfiguration(),
            let description = Self.configurationIssueDescription(for: runtimeConfiguration)
        {
            throw AppleSignInError.configurationIssue(description)
        }

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
        let tokenSummary = AppleTokenSummary(idToken: idToken)
        AppleSignInService.logger.debug(
            """
            [Apple Sign In] received identity token (first 20 chars): \
            \(String(idToken.prefix(20)), privacy: .public)... \
            aud=\(tokenSummary.audience ?? "<missing>", privacy: .public) \
            iss=\(tokenSummary.issuer ?? "<missing>", privacy: .public) \
            sub=\(tokenSummary.subject ?? "<missing>", privacy: .private(mask: .hash))
            """
        )
        continuation?.resume(returning: idToken)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let nsError = error as NSError
        let runtimeConfiguration = Self.currentRuntimeConfiguration()
        AppleSignInService.logger.error(
            """
            [Apple Sign In] error domain=\(nsError.domain, privacy: .public) \
            code=\(nsError.code, privacy: .public) \
            message=\(error.localizedDescription, privacy: .public) \
            bundleID=\(runtimeConfiguration?.bundleIdentifier ?? "<unknown>", privacy: .public) \
            teamID=\(runtimeConfiguration?.teamIdentifier ?? "<none>", privacy: .public) \
            hasEntitlement=\(runtimeConfiguration?.hasAppleSignInEntitlement == true, privacy: .public)
            """
        )
        continuation?.resume(throwing: Self.mapSystemError(error, runtimeConfiguration: runtimeConfiguration))
        continuation = nil
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

extension AppleSignInService {
    struct AppleTokenSummary {
        let audience: String?
        let issuer: String?
        let subject: String?

        init(idToken: String) {
            guard
                let payload = Self.decodePayload(from: idToken),
                let jsonObject = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else {
                audience = nil
                issuer = nil
                subject = nil
                return
            }

            audience = Self.stringValue(for: "aud", in: jsonObject)
            issuer = Self.stringValue(for: "iss", in: jsonObject)
            subject = Self.stringValue(for: "sub", in: jsonObject)
        }

        private static func decodePayload(from idToken: String) -> Data? {
            let segments = idToken.split(separator: ".")
            guard segments.count >= 2 else { return nil }

            var base64 = String(segments[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            let remainder = base64.count % 4
            if remainder != 0 {
                base64.append(String(repeating: "=", count: 4 - remainder))
            }

            return Data(base64Encoded: base64)
        }

        private static func stringValue(for key: String, in object: [String: Any]) -> String? {
            if let value = object[key] as? String {
                return value
            }

            if let values = object[key] as? [String] {
                return values.joined(separator: ",")
            }

            return nil
        }
    }

    enum Availability: Equatable {
        case available
        case unavailable(String)
        case unknown
    }

    struct RuntimeConfiguration: Equatable {
        let bundleIdentifier: String?
        let teamIdentifier: String?
        let hasAppleSignInEntitlement: Bool
    }

    nonisolated static func currentAvailability() -> Availability {
        guard let runtimeConfiguration = currentRuntimeConfiguration() else {
            return .unknown
        }

        if let description = configurationIssueDescription(for: runtimeConfiguration) {
            return .unavailable(description)
        }

        return .available
    }

    nonisolated static func mapSystemError(
        _ error: Error,
        runtimeConfiguration: RuntimeConfiguration?
    ) -> Error {
        let nsError = error as NSError
        guard
            nsError.domain == ASAuthorizationError.errorDomain,
            nsError.code == ASAuthorizationError.unknown.rawValue,
            let runtimeConfiguration,
            let description = configurationIssueDescription(for: runtimeConfiguration)
        else {
            return error
        }

        return AppleSignInError.configurationIssue(description)
    }

    nonisolated static func configurationIssueDescription(
        for runtimeConfiguration: RuntimeConfiguration
    ) -> String? {
        if !runtimeConfiguration.hasAppleSignInEntitlement {
            return """
            Sign In with Apple is not enabled in this dev build. For manually \
            assembled macOS app bundles, Apple Sign In needs both the bundled \
            entitlement and a matching embedded macOS provisioning profile. \
            Rebuild with `TYPEFLUX_DEV_PROVISIONING_PROFILE=/path/to/profile.provisionprofile`.
            """
        }

        let teamIdentifier = runtimeConfiguration.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if teamIdentifier?.isEmpty != false {
            return """
            Sign In with Apple requires both a real Apple Development signature \
            and a matching embedded macOS provisioning profile. Ad-hoc signed \
            builds can launch, but Apple login is unavailable.
            """
        }

        return nil
    }

    private nonisolated static func currentRuntimeConfiguration() -> RuntimeConfiguration? {
        var selfCode: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &selfCode)
        guard copySelfStatus == errSecSuccess, let selfCode else {
            logger.error("[Apple Sign In] failed to inspect code signature: \(copySelfStatus, privacy: .public)")
            return nil
        }

        var staticCode: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(selfCode, [], &staticCode)
        guard copyStaticStatus == errSecSuccess, let staticCode else {
            logger.error("[Apple Sign In] failed to inspect static code signature: \(copyStaticStatus, privacy: .public)")
            return nil
        }

        var signingInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess,
              let info = signingInformation as? [String: Any]
        else {
            logger.error("[Apple Sign In] failed to inspect signing information: \(status, privacy: .public)")
            return nil
        }

        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let appleSignInValues = entitlements?["com.apple.developer.applesignin"] as? [String]
        let hasAppleSignInEntitlement = appleSignInValues?.contains("Default") == true

        return RuntimeConfiguration(
            bundleIdentifier: info[kSecCodeInfoIdentifier as String] as? String ?? Bundle.main.bundleIdentifier,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            hasAppleSignInEntitlement: hasAppleSignInEntitlement
        )
    }
}

// MARK: - Errors

enum AppleSignInError: LocalizedError {
    case missingIDToken
    case internalError
    case configurationIssue(String)

    var errorDescription: String? {
        switch self {
        case .missingIDToken:
            "Failed to retrieve Apple ID token."
        case .internalError:
            "An internal error occurred during Apple Sign In."
        case .configurationIssue(let description):
            description
        }
    }
}
