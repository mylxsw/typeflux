import AuthenticationServices
import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS
import UIKit

@MainActor
@Suite("Google browser session lifecycle")
struct GoogleSignInTests {
    private let clientID = "123-ios.apps.googleusercontent.com"

    @Test func `valid callback exchanges the code and uses the active presentation window`() async throws {
        let window = UIWindow()
        let browser = FakeGoogleBrowser()
        let service = GoogleSignIn(clientID: clientID, makeSession: { url, scheme, completion in
            browser.onStart = {
                #expect(browser.presentationContextProvider?.presentationAnchor(for: ASWebAuthenticationSession(
                    url: url, callbackURLScheme: scheme, completionHandler: { _, _ in }
                )) === window)
                completion(callback(url: url, scheme: scheme), nil)
            }
            return browser
        }, windowProvider: { window }, exchange: { auth, code in
            #expect(auth.clientID == clientID)
            #expect(code == "test-code")
            return "id-token"
        })
        #expect(try await service.signIn() == "id-token")
    }

    @Test func `start failure missing window and missing configuration report errors`() async {
        let window = UIWindow()
        let browser = FakeGoogleBrowser()
        browser.starts = false
        let service = GoogleSignIn(clientID: clientID, makeSession: { _, _, _ in browser },
                                   windowProvider: { window })
        await #expect(throws: GoogleOAuthError.failed) { try await service.signIn() }
        let noWindow = GoogleSignIn(clientID: clientID, windowProvider: { nil })
        await #expect(throws: GoogleOAuthError.failed) { try await noWindow.signIn() }
        await #expect(throws: GoogleOAuthError.notConfigured) { try await GoogleSignIn(clientID: "").signIn() }
    }

    @Test func `browser cancellation failures and absent callbacks do not exchange tokens`() async {
        let window = UIWindow()
        for kind in 0 ... 2 {
            let browser = FakeGoogleBrowser()
            let service = GoogleSignIn(clientID: clientID, makeSession: { _, _, completion in
                browser.onStart = {
                    let error: (any Error)? = switch kind {
                    case 0: ASWebAuthenticationSessionError(.canceledLogin)
                    case 1: URLError(.notConnectedToInternet)
                    default: nil
                    }
                    completion(nil, error)
                }
                return browser
            }, windowProvider: { window }, exchange: { _, _ in
                Issue.record("An invalid callback must not exchange a token")
                return "unexpected"
            })
            do {
                _ = try await service.signIn()
                Issue.record("Expected an authorization error")
            } catch {
                if kind == 0 {
                    #expect(error is CancellationError)
                }
                if kind == 1 {
                    #expect(error as? GoogleOAuthError == .failed)
                }
                if kind == 2 {
                    #expect(error as? GoogleOAuthError == .invalidCallback)
                }
            }
        }
    }

    @Test func `task cancellation cancels browser and stale completion cannot finish the next attempt`() async throws {
        let window = UIWindow()
        let starts = AsyncStream<Void>.makeStream()
        defer { starts.continuation.finish() }
        var iterator = starts.stream.makeAsyncIterator()
        var browsers: [FakeGoogleBrowser] = []
        var completions: [GoogleSignIn.Completion] = []
        var callbacks: [URL] = []
        let service = GoogleSignIn(clientID: clientID, makeSession: { url, scheme, completion in
            let browser = FakeGoogleBrowser()
            browser.onStart = { starts.continuation.yield(()) }
            browsers.append(browser)
            completions.append(completion)
            callbacks.append(callback(url: url, scheme: scheme))
            return browser
        }, windowProvider: { window }, exchange: { _, _ in "id-token" })
        let first = Task { try await service.signIn() }
        _ = await iterator.next()
        // A concurrent attempt must not replace the pending continuation.
        await #expect(throws: GoogleOAuthError.failed) { try await service.signIn() }
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Cancellation must terminate authorization")
        } catch { #expect(error is CancellationError) }
        #expect(browsers[0].cancelled)
        let second = Task { try await service.signIn() }
        _ = await iterator.next()
        completions[0](callbacks[0], nil)
        completions[1](callbacks[1], nil)
        #expect(try await second.value == "id-token")
    }

    private func callback(url: URL, scheme: String) -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            .first { $0.name == "state" }!.value!
        return URL(string: scheme + ":/?state=" + state + "&code=test-code")!
    }
}

@MainActor
private final class FakeGoogleBrowser: GoogleAuthenticationSession {
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var starts = true
    var cancelled = false
    var onStart: (() -> Void)?

    func start() -> Bool {
        onStart?()
        return starts
    }

    func cancel() {
        cancelled = true
    }
}
