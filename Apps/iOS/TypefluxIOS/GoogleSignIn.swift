import AuthenticationServices
import TypefluxChat
import UIKit

@MainActor
protocol GoogleSignInAuthorizing {
    func signIn() async throws -> String
}

@MainActor
protocol GoogleAuthenticationSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: GoogleAuthenticationSession {}

/// Owns the browser session until completion; dismissal and task cancellation are benign.
@MainActor
final class GoogleSignIn: NSObject, GoogleSignInAuthorizing, ASWebAuthenticationPresentationContextProviding {
    typealias Completion = @Sendable (URL?, (any Error)?) -> Void
    typealias SessionFactory = (URL, String, @escaping Completion) -> any GoogleAuthenticationSession

    private let clientID: String
    private let makeSession: SessionFactory
    private let windowProvider: () -> UIWindow?
    private let exchange: (GoogleOAuthAuthorization, String) async throws -> String
    private var attemptID: UUID?
    private var browser: (any GoogleAuthenticationSession)?
    private var continuation: CheckedContinuation<URL, Error>?
    private weak var window: UIWindow?

    static var configuredClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_IOS_CLIENT_ID") as? String ?? ""
    }

    init(
        clientID: String = GoogleSignIn.configuredClientID,
        makeSession: @escaping SessionFactory = { url, scheme, completion in
            ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
        },
        windowProvider: @escaping () -> UIWindow? = {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
        },
        exchange: @escaping (GoogleOAuthAuthorization, String) async throws -> String = {
            try await $0.exchange(code: $1)
        }
    ) {
        self.clientID = clientID
        self.makeSession = makeSession
        self.windowProvider = windowProvider
        self.exchange = exchange
    }

    func signIn() async throws -> String {
        let attempt = UUID()
        let authorization = try GoogleOAuthAuthorization.make(clientID: clientID)
        try Task.checkCancellation()
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard self.continuation == nil,
                      let window = windowProvider() else {
                    continuation.resume(throwing: GoogleOAuthError.failed)
                    return
                }
                self.attemptID = attempt
                self.window = window
                self.continuation = continuation
                let browser = makeSession(authorization.url, authorization.callbackScheme) { url, error in
                    Task { @MainActor in
                        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                            self.finish(.failure(CancellationError()), attempt: attempt)
                        } else if error != nil {
                            self.finish(.failure(GoogleOAuthError.failed), attempt: attempt)
                        } else if let url {
                            self.finish(.success(url), attempt: attempt)
                        } else {
                            self.finish(.failure(GoogleOAuthError.invalidCallback), attempt: attempt)
                        }
                    }
                }
                self.browser = browser
                browser.presentationContextProvider = self
                if !browser.start() {
                    finish(.failure(GoogleOAuthError.failed), attempt: attempt)
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.attemptID == attempt else { return }
                self.browser?.cancel()
                self.finish(.failure(CancellationError()), attempt: attempt)
            }
        }
        try Task.checkCancellation()
        return try await exchange(authorization, authorization.code(from: callback))
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<URL, Error>, attempt: UUID) {
        guard attemptID == attempt else { return }
        attemptID = nil
        let pending = continuation
        continuation = nil
        browser = nil
        window = nil
        pending?.resume(with: result)
    }
}
