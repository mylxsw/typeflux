import AppKit
import AuthenticationServices

@MainActor
final class WebLoginBrowser: NSObject, WebLoginBrowserSession, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession!

    init(url: URL, scheme: String, completion: @escaping (URL?, Bool) -> Void) {
        super.init()
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            Task { @MainActor in completion(url, cancelled) }
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
    }

    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
