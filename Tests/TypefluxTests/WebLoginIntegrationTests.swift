import AppKit
import AuthenticationServices
import SwiftUI
import Testing
@testable import Typeflux
import Vision

@Suite("Web login AuthState integration", .exclusiveUIState)
@MainActor
struct WebLoginIntegrationTests {
    private func auth() -> AuthState {
        AuthState(
            loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil },
            saveStoredUserProfile: { _ in },
            fetchProfile: { _ in
                UserProfile(id: "web-user", email: "web@example.test", name: "Web User", status: 1,
                            provider: "password", createdAt: "2026-10-12", updatedAt: "2026-10-12")
            }, fetchSubscription: { _ in .none }
        )
    }

    @Test func `keychain session and existing login notification`() async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
        defer {
            KeychainTokenStore.clearAll()
            KeychainTokenStore.useInMemoryStoreForTesting = false
        }
        let state = auth()
        defer { state.refreshTimer?.invalidate() }
        let notification = NotificationCounter()
        let observer = NotificationCenter.default
            .addObserver(forName: .authDidLogin, object: state, queue: .main) { _ in
                notification.increment()
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let expiry = Int(Date().timeIntervalSince1970) + 3600
        try await state.acceptWebLogin(
            .init(accessToken: "web-access", expiresAt: expiry, refreshToken: "web-refresh"),
            generation: state.sessionGeneration
        )
        #expect(state.isLoggedIn && state.userProfile?.id == "web-user")
        #expect(state.accessToken == "web-access" && notification.count == 1)
        #expect(KeychainTokenStore.loadToken()?.token == "web-access")
        #expect(KeychainTokenStore.loadRefreshToken() == "web-refresh")
        #expect(KeychainTokenStore.loadToken()?.expiresAt == expiry)
        // Existing sessions still restore independently of the feature gate.
        let restored = AuthState(
            fetchProfile: { _ in throw URLError(.notConnectedToInternet) },
            refreshAccessToken: { _ in throw URLError(.notConnectedToInternet) }
        )
        defer { restored.refreshTimer?.invalidate() }
        #expect(restored.isLoggedIn && restored.accessToken == "web-access")
        await Task.yield()
    }

    @Test func `failed persistence and old generation cannot login`() async {
        let state = auth()
        defer { state.refreshTimer?.invalidate() }
        let response = LoginResponse(
            accessToken: "a",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            refreshToken: "r"
        )
        await #expect(throws: WebLoginFailure.storageFailed) {
            try await state.acceptWebLogin(response, generation: state.sessionGeneration, persist: { _, _, _ in false })
        }
        #expect(!state.isLoggedIn)
        var saved = false
        await #expect(throws: WebLoginFailure.restartRequired) {
            try await state.acceptWebLogin(
                response,
                generation: state.sessionGeneration - 1,
                persist: { _, _, _ in saved = true; return true }
            )
        }
        #expect(!saved && !state.isLoggedIn)
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
}

@Suite("Web login presentation", .exclusiveUIState)
@MainActor
struct WebLoginPresentationTests {
    @Test func browserAdapterOpensDefaultBrowserWithoutNativePresentation() {
        let url = URL(string: "http://localhost:5174/login?transaction=test")!
        var opened: [URL] = []
        let browser = WebLoginBrowser(url: url, scheme: "test-auth", completion: { _, _ in
            Issue.record("External browser callbacks must arrive through the App URL router")
        }, open: { opened.append($0); return true })
        browser.cancel()
        #expect(opened.isEmpty)
        #expect(browser.start())
        #expect(opened == [url])
        browser.cancel()
        #expect(opened == [url])
        let unavailable = WebLoginBrowser(url: url, scheme: "test-auth", completion: { _, _ in }, open: { _ in false })
        #expect(!unavailable.start())
    }

    @Test func loginClickStartsBrowserWithoutWindowAndRetainsPendingTransaction() async throws {
        let configuration = WebLoginConfiguration.resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"], info: [:])
        let api = PresentationWebAPI()
        let store = WebLoginMemoryStore()
        var opened: [URL] = []
        var accepted = 0
        let coordinator = WebLoginCoordinator(configuration: configuration, api: api, store: store,
            browserFactory: { url, scheme, callback in
                WebLoginBrowser(url: url, scheme: scheme, completion: callback, open: { opened.append($0); return true })
            }, authGeneration: { 0 }, accept: { _, _ in accepted += 1 })
        var nativeWindows = 0
        var failures: [WebLoginFailure] = []
        let entry = WebLoginEntryController(coordinator: coordinator, showNative: { nativeWindows += 1 },
                                           reportFailure: { failures.append($0) })
        entry.show()
        entry.show()
        try await Task.sleep(for: .milliseconds(30))
        #expect(nativeWindows == 0 && opened.count == 1 && store.pending != nil)
        entry.show()
        #expect(opened.count == 2 && opened[0] == opened[1])
        await AppLoginURLRouter.handle([api.callback], login: coordinator, isLoggedIn: { accepted > 0 },
                                      showLogin: { entry.showCurrentFailure() }, handleBilling: {})
        #expect(accepted == 1 && store.pending == nil && nativeWindows == 0 && failures.isEmpty)
        coordinator.cancel()
    }

    @Test func entryReportsFailureOnceAndKeepsNativeFallback() async throws {
        let config = WebLoginConfiguration.resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"], info: [:])
        let api = PresentationWebAPI()
        api.createFailure = .networkUnavailable
        let coordinator = WebLoginCoordinator(configuration: config, api: api, store: WebLoginMemoryStore(),
            browserFactory: { _, _, _ in Issue.record("Failed creation must not open a browser"); return PresentationBrowser() },
            authGeneration: { 0 }, accept: { _, _ in })
        var nativeWindows = 0
        var failures: [WebLoginFailure] = []
        let entry = WebLoginEntryController(coordinator: coordinator, showNative: { nativeWindows += 1 },
                                           reportFailure: { failures.append($0) })
        entry.show()
        try await Task.sleep(for: .milliseconds(30))
        entry.showCurrentFailure()
        #expect(failures == [.networkUnavailable] && nativeWindows == 0)
        entry.show()
        try await Task.sleep(for: .milliseconds(30))
        #expect(failures == [.networkUnavailable, .networkUnavailable])
        let disabled = WebLoginCoordinator(configuration: .resolve(environment: [:], info: [:]), api: api,
            store: WebLoginMemoryStore(), browserFactory: { _, _, _ in PresentationBrowser() },
            authGeneration: { 0 }, accept: { _, _ in })
        let fallback = WebLoginEntryController(coordinator: disabled, showNative: { nativeWindows += 1 }, reportFailure: { _ in })
        fallback.show()
        #expect(nativeWindows == 1 && disabled.phase == .idle)
    }

    @Test func waitingAndRecoveryViewsTrackCoordinator() async throws {
        _ = NSApplication.shared
        let configuration = WebLoginConfiguration.resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"], info: [:])
        let api = PresentationWebAPI()
        let coordinator = WebLoginCoordinator(configuration: configuration, api: api, store: WebLoginMemoryStore(),
            browserFactory: { _, _, _ in PresentationBrowser() }, authGeneration: { 0 }, accept: { _, _ in })
        var dismissed = false
        let hosting = NSHostingView(rootView: WebLoginView(coordinator: coordinator, onDismiss: { dismissed = true }))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close(); coordinator.cancel() }
        for failure in [WebLoginFailure.expired, .browserUnavailable, .storageFailed, .restartRequired] {
            api.failure = failure
            await coordinator.start()
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            #expect(coordinator.phase == .waiting)
            coordinator.reopen()
            await coordinator.receive(api.callback)
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            #expect(coordinator.phase == .failed(failure))
            #expect(!L(failure.localizationKey).hasPrefix("auth.web."))
        }
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        api.failure = nil
        await coordinator.start()
        await coordinator.receive(api.callback)
        try await Task.sleep(for: .milliseconds(50))
        #expect(dismissed)
    }

    @Test func `renders localized browser entry`() async throws {
        _ = NSApplication.shared
        let oldLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(oldLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        #expect(L("auth.web.continue") == "在浏览器中继续")
        let configuration = WebLoginConfiguration.resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"], info: [:])
        let coordinator = WebLoginCoordinator(
            configuration: configuration,
            api: WebLoginHTTPAPI(configuration: configuration),
            store: WebLoginMemoryStore(),
            browserFactory: { WebLoginBrowser(url: $0, scheme: $1, completion: $2) },
            authGeneration: { 0 },
            accept: { _, _ in }
        )
        for dark in [false, true] {
            let hosting = NSHostingView(rootView: WebLoginView(coordinator: coordinator, onDismiss: {})
                .environment(\.colorScheme, dark ? .dark : .light))
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.appearance = hosting.appearance
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1040, pixelsHigh: 1240,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
            let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? ""
            #expect(text.contains("Typeflux"))
            #expect(text.contains("浏览器"))
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_WEB_LOGIN_SCREENSHOTS"] {
                let root = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent(dark ? "web-login-dark.png" : "web-login-light.png"))
            }
        }
    }
}

@MainActor
private final class PresentationBrowser: WebLoginBrowserSession {
    func start() -> Bool { true }
    func cancel() {}
}

@MainActor
private final class PresentationWebAPI: WebLoginAPI {
    var failure: WebLoginFailure?
    var createFailure: WebLoginFailure?
    private var state = ""
    private let identifier = String(repeating: "a", count: 43)
    var callback: URL {
        URL(string: "ai.gulu.app.typeflux://auth/callback?code=\(identifier)&state=\(state)")!
    }
    func create(proof: WebLoginProof) async throws -> WebLoginTransaction {
        if let createFailure { throw createFailure }
        state = proof.state
        return WebLoginTransaction(transactionID: identifier,
            loginURL: "https://typeflux.app/login?transaction=\(identifier)",
            expiresAt: Date().timeIntervalSince1970 + 600)
    }
    func exchange(code: String, verifier: String) async throws -> LoginResponse {
        if let failure { throw failure }
        return LoginResponse(accessToken: "preview-access", expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                             refreshToken: "preview-refresh")
    }
}
