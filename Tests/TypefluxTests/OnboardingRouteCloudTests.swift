// swiftlint:disable file_length
import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingRouteCloudTests {
    private typealias TestUI = SettingsBehaviorTestSupport

    private func auth(paid: Bool = true, fails: Bool = false,
                      fetch: ((String) async throws -> BillingSubscriptionSnapshot)? = nil) -> AuthState {
        let state = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                              loadStoredUserProfile: { nil }, saveStoredToken: { _, _ in },
                              saveStoredUserProfile: { _ in }, clearStoredSession: {}, fetchSubscription: { token in
                                  if let fetch {
                                      return try await fetch(token)
                                  }
                                  if fails {
                                      throw URLError(.notConnectedToInternet)
                                  }
                                  return .init(
                                      planCode: paid ? "pro" : "free",
                                      status: "active",
                                      currentPeriodStart: nil,
                                      currentPeriodEnd: nil,
                                      cancelAtPeriodEnd: false,
                                      entitled: true,
                                      cloudASRAllowed: paid
                                  )
                              })
        state.inMemorySessionToken = ("fixture", Int(Date().timeIntervalSince1970) + 3600)
        state.isLoggedIn = true
        state.userProfile = .init(id: "fixture", email: "alex@example.com", name: "Alex Chen", status: 1,
                                  provider: "password", createdAt: "", updatedAt: "")
        return state
    }

    private func session(_ settings: SettingsStore, auth: AuthState, manager: CloudFixtureManager? = nil)
        -> OnboardingViewModel {
        OnboardingViewModel(settingsStore: settings, authState: auth,
                            modelLibrary: AskModelLibrary(
                                defaults: settings.defaults,
                                automaticallyLoadsCatalog: false
                            ),
                            localModelManager: manager, onComplete: {})
    }

    @Test func `route choices and launcher skip preserve configuration`() async throws {
        try await TestUI.withFixture { settings in
            let session = session(settings, auth: auth())
            session.currentStep = .route
            session.chooseRoute(.custom)
            #expect(session.currentStep == .route && session.serviceRoute == .custom)
            session.chooseRoute(.cloud)
            session.advance()
            #expect(session.currentStep == .cloud)
            session.goBack()
            session.requestSetupSkip()
            #expect(session.skipConfirmation == .allModels)
            session.skipConfirmation = nil
            #expect(session.serviceRoute == .cloud)
            session.requestSetupSkip(); session.confirmSkip()
            #expect(session.currentStep == .permissions && session.serviceRoute == .launcherOnly)
            #expect(settings.onboardingSpeechDeferred && settings.onboardingAIDeferred)
        }
    }

    @Test func `entitlement gates continuation and hands off cloud defaults explicitly`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            #expect(!session.canAdvance)
            session.cloudModel.refresh()
            session.cloudModel.refresh() // Coalesce an in-flight refresh.
            try await TestUI.wait { session.cloudModel.entitlementReady }
            #expect(session.canAdvance && session.cloudModel.cloudSpeech)
            #expect(session.cloudModel.planName == "Pro")
            #expect(session.cloudModel.profile?.email == "alex@example.com")
            #expect(session.currentStep == .cloud)
            state.subscriptionError = "fixture"
            try await TestUI.wait { session.cloudModel.error != nil }
            #expect(!session.canAdvance)
            state.subscriptionError = nil
            session.cloudModel.retry()
            try await TestUI.wait { session.canAdvance }
            session.advance()
            #expect(session.currentStep == .permissions)
            #expect(settings.sttProvider == .typefluxOfficial)
            #expect(session.modelLibrary.defaultReference == "cloud:default")
            #expect(session.modelLibrary.rewriteReference == "cloud:default")
            state.sessionGeneration += 1
            session.cloudModel.updateReadiness()
            #expect(session.cloudModel.canContinue == false)
        }
    }

    @Test func `free plan downloads local speech and failure retries inline`() async throws {
        try await TestUI.withFixture { settings in
            let manager = CloudFixtureManager()
            settings.localSTTModelIdentifier = "previous-model"
            let session = session(settings, auth: auth(paid: false), manager: manager)
            session.currentStep = .cloud
            let model = session.cloudModel
            model.refresh()
            try await TestUI.wait { model.entitlementReady }
            #expect(!session.canAdvance && !model.cloudSpeech)
            manager.failure = true
            model.downloadLocalModel()
            try await TestUI.wait { model.error != nil }
            #expect(!session.canAdvance && model.downloadProgress == nil)
            manager.failure = false
            model.retry()
            model.downloadLocalModel()
            try await TestUI.wait { model.localReady }
            #expect(session.canAdvance && manager.preparations == 2)
            #expect(settings.localSTTModel == .senseVoiceSmall)
            #expect(settings.localSTTModelIdentifier == LocalSTTModel.senseVoiceSmall.defaultModelIdentifier)
            manager.available = false
            session.refreshSetup()
            try await TestUI.wait { model.canContinue == false }
            manager.available = true
            session.refreshSetup()
            try await TestUI.wait { model.canContinue == true }
            session.advance()
            #expect(settings.sttProvider == .localModel && !settings.onboardingSpeechDeferred)
            #expect(session.currentStep == .permissions)
        }
    }

    @Test func `failed entitlement and late downloads never navigate or change settings`() async throws {
        try await TestUI.withFixture { settings in
            let manager = CloudFixtureManager()
            manager.paused = true
            let session = session(settings, auth: auth(paid: false, fails: true), manager: manager)
            session.currentStep = .cloud
            let model = session.cloudModel
            model.refresh()
            try await TestUI.wait { model.error != nil }
            #expect(!model.entitlementReady && !session.canAdvance)
            let previous = settings.sttProvider
            model.downloadLocalModel()
            try await TestUI.wait { manager.continuation != nil }
            session.useCustomModels()
            manager.continuation?.resume(); manager.continuation = nil
            await Task.yield()
            #expect(session.currentStep == .speech && settings.sttProvider == previous)
            #expect(model.downloadProgress == nil && !model.isBusy)
        }
    }

    @Test func `subscription refresh cannot erase a newer download failure`() async throws {
        try await TestUI.withFixture { settings in
            var pending: CheckedContinuation<BillingSubscriptionSnapshot, Never>?
            var calls = 0
            let state = auth(fetch: { _ in
                calls += 1
                if calls == 1 {
                    return .none
                }
                return await withCheckedContinuation { pending = $0 }
            })
            defer { pending?.resume(returning: .none); pending = nil }
            let manager = CloudFixtureManager()
            manager.failure = true
            let session = session(settings, auth: state, manager: manager)
            session.currentStep = .cloud
            let model = session.cloudModel
            model.refresh()
            try await TestUI.wait { model.entitlementReady }
            model.refresh()
            try await TestUI.wait { pending != nil }
            model.downloadLocalModel()
            try await TestUI.wait { model.error != nil }
            pending?.resume(returning: .none); pending = nil
            try await TestUI.wait { !model.isBusy }
            #expect(model.error != nil && model.canContinue == false)
            manager.failure = false
            model.retry()
            try await TestUI.wait { model.localReady }
            #expect(model.error == nil && session.canAdvance)
        }
    }

    @Test func `an in-flight account refresh is awaited before validating cloud availability`() async throws {
        try await TestUI.withFixture { settings in
            var firstLoad: CheckedContinuation<BillingSubscriptionSnapshot, Never>?
            var calls = 0
            let state = auth(fetch: { _ in
                calls += 1
                if calls == 1 {
                    return await withCheckedContinuation { firstLoad = $0 }
                }
                return .none
            })
            let background = Task { await state.refreshSubscription() }
            defer { firstLoad?.resume(returning: .none); firstLoad = nil }
            try await TestUI.wait { firstLoad != nil }
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            session.cloudModel.activate()
            #expect(session.cloudModel.isBusy && !session.canAdvance)
            firstLoad?.resume(returning: .none); firstLoad = nil
            _ = await background.value
            try await TestUI.wait { session.cloudModel.entitlementReady }
            #expect(calls == 2 && session.cloudModel.error == nil)
            #expect(!session.canAdvance)
        }
    }

    @Test func `late entitlement results cannot unlock a departed or replaced account`() async throws {
        try await TestUI.withFixture { settings in
            for replaceAccount in [false, true] {
                var continuation: CheckedContinuation<BillingSubscriptionSnapshot, Never>?
                let state = auth(fetch: { _ in await withCheckedContinuation { continuation = $0 } })
                let session = session(settings, auth: state)
                session.currentStep = .cloud
                let model = session.cloudModel
                model.refresh()
                try await TestUI.wait { continuation != nil }
                if replaceAccount {
                    state.sessionGeneration += 1
                } else {
                    session.goBack()
                }
                continuation?.resume(returning: .none); continuation = nil
                try await TestUI.wait { !model.isBusy }
                #expect(!model.entitlementReady && model.canContinue == false)
                #expect(session.currentStep == (replaceAccount ? .cloud : .route))
            }
        }
    }

    @Test func `inline browser lifecycle rejects callbacks after leaving cloud`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            state.isLoggedIn = false
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            let api = CloudFixtureAPI()
            let browser = CloudFixtureBrowser()
            let login = coordinator(api: api, browser: browser)
            let model = OnboardingCloudModel(session: session, login: login)
            #expect(model.phase == .idle && model.canContinue == false)
            await model.start()
            #expect(model.phase == .waiting && model.isBusy)
            model.reopen()
            #expect(browser.starts == 2)
            model.cancel()
            #expect(model.phase == .cancelled && !model.isBusy)
            api.fail = true
            await model.start()
            #expect(model.phase == .failed(.browserUnavailable) && !model.isBusy)
            api.fail = false
            await model.start()
            session.goBack()
            #expect(model.phase == .cancelled && session.currentStep == .route)
            await login.receive(callback)
            #expect(api.exchanges == 0)
            await model.switchAccount()
            await model.start()
            #expect(!state.isLoggedIn && model.phase == .cancelled)
            model.deactivate()
        }
    }
}

extension OnboardingRouteCloudTests {
    @Test func `a download failure from an older account is ignored`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth(paid: false)
            let manager = CloudFixtureManager()
            manager.failure = true
            let session = session(settings, auth: state, manager: manager)
            session.currentStep = .cloud
            let model = session.cloudModel
            let previous = settings.sttProvider
            model.downloadLocalModel()
            state.sessionGeneration += 1
            try await TestUI.wait { !model.isBusy }
            #expect(model.error == nil && model.canContinue == false)
            #expect(settings.sttProvider == previous)
        }
    }

    @Test func `successful browser login checks entitlement without advancing or presenting a modal`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            state.isLoggedIn = false
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            let api = CloudFixtureAPI()
            weak var acceptingModel: OnboardingCloudModel?
            let login = coordinator(api: api, browser: CloudFixtureBrowser()) { _, _ in
                state.isLoggedIn = true
                #expect(acceptingModel?.signedIn == false)
            }
            let model = OnboardingCloudModel(session: session, login: login)
            acceptingModel = model
            await model.start()
            await login.receive(callback)
            try await TestUI.wait { model.entitlementReady }
            #expect(model.phase == .succeeded && model.canContinue == true)
            #expect(session.currentStep == .cloud)
            #expect(NSApp.modalWindow == nil)
            state.isLoggedIn = false
            #expect(!model.entitlementReady && model.canContinue == false)
            await model.start()
            #expect(model.phase == .waiting)
            state.isLoggedIn = true
            model.cancel()
            try await TestUI.wait { model.entitlementReady }
            #expect(model.canContinue == true && session.currentStep == .cloud)
            model.deactivate()
        }
    }

    @Test func `onboarding owns login callbacks and leaves global presentation silent`() async throws {
        try await TestUI.withFixture { settings in
            for fails in [false, true] {
                let state = auth()
                state.isLoggedIn = false
                let session = session(settings, auth: state)
                session.currentStep = .cloud
                #expect(session.cloudModel.login !== state.webLoginCoordinator)
                let api = CloudFixtureAPI()
                api.exchangeFailure = fails ? .restartRequired : nil
                let login = coordinator(api: api, browser: CloudFixtureBrowser()) { _, _ in
                    state.isLoggedIn = true
                }
                let model = OnboardingCloudModel(session: session, login: login)
                let globalAPI = CloudFixtureAPI()
                let global = coordinator(api: globalAPI, browser: CloudFixtureBrowser())
                state.webLoginCoordinator = global
                var presentations = 0
                let entry = WebLoginEntryController(coordinator: global, showNative: { presentations += 1 },
                                                    reportFailure: { _ in presentations += 1 },
                                                    reportSuccess: { presentations += 1 })
                let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
                defer {
                    for window in NSApp.windows where !existingWindows.contains(ObjectIdentifier(window)) {
                        window.close()
                    }
                    model.endSession()
                    withExtendedLifetime(entry) {}
                }
                session.cloudModel = model
                let visibleWindows = NSApp.windows.filter(\.isVisible).count
                LoginWindowController.shared.show()
                try await TestUI.wait { model.phase == .waiting }
                #expect(NSApp.windows.filter(\.isVisible).count == visibleWindows)
                #expect(OnboardingCloudModel.activeLogin === login)
                await AppLoginURLRouter.handle([callback], login: global, isLoggedIn: { state.isLoggedIn },
                                               showLogin: { presentations += 1 }, handleBilling: {})
                await Task.yield()
                #expect(api.exchanges == 1 && globalAPI.exchanges == 0 && presentations == 0)
                #expect(model.phase == (fails ? .failed(.restartRequired) : .succeeded))
                model.deactivate()
                #expect(OnboardingCloudModel.activeLogin == nil)
            }
        }
    }

    @Test func `a callback after Back never reopens the global login entry`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            state.isLoggedIn = false
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            let api = CloudFixtureAPI()
            let model = OnboardingCloudModel(
                session: session,
                login: coordinator(api: api, browser: CloudFixtureBrowser())
            )
            await model.start()
            session.goBack()
            var presentations = 0
            let globalAPI = CloudFixtureAPI()
            let global = coordinator(api: globalAPI, browser: CloudFixtureBrowser())
            await AppLoginURLRouter.handle([callback], login: global, isLoggedIn: { state.isLoggedIn },
                                           showLogin: { presentations += 1 }, handleBilling: {})
            #expect(model.phase == .cancelled && session.currentStep == .route)
            #expect(api.exchanges == 0 && globalAPI.exchanges == 0 && presentations == 0)
            model.endSession()
        }
    }

    @Test func `resumed onboarding defers account prompts and preserves the normal defaults handoff`() async throws {
        try await TestUI.withFixture { settings in
            settings.isOnboardingCompleted = true
            settings.sttProvider = .whisperAPI
            settings.llmProvider = .openAICompatible
            settings.llmRemoteProvider = .openAI
            let session = session(settings, auth: auth())
            session.resumeDeferredSetup()
            let prompt = CloudFixturePrompt()
            let sync = CloudLoginSyncCoordinator(settingsStore: settings, promptPresenter: prompt,
                                                 hasPaidCloudSubscription: { true })
            defer { session.cloudModel.endSession() }
            sync.offerCloudDefaultsIfNeeded()
            #expect(prompt.calls == 0 && !LoginWindowController.shouldPresentWebLoginAlerts)
            session.cloudModel.endSession()
            sync.offerCloudDefaultsIfNeeded()
            #expect(prompt.calls == 1 && LoginWindowController.shouldPresentWebLoginAlerts)
            #expect(settings.sttProvider == .whisperAPI && settings.llmRemoteProvider == .openAI)
        }
    }

    @Test func `disabled web rollout fails inline without opening a browser`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            state.isLoggedIn = false
            let session = session(settings, auth: state)
            session.currentStep = .cloud
            let browser = CloudFixtureBrowser()
            let login = coordinator(api: CloudFixtureAPI(), browser: browser, enabled: false)
            let model = OnboardingCloudModel(session: session, login: login)
            await model.start()
            #expect(model.phase == .failed(.restartRequired) && model.canContinue == false)
            #expect(browser.starts == 0 && OnboardingCloudModel.activeLogin == nil)
        }
    }

    @Test func `closing the native onboarding window cancels pending login`() async throws {
        try await TestUI.withFixture { settings in
            let controller = OnboardingWindowController()
            controller.show(settingsStore: settings, onComplete: {})
            let nativeWindow = try #require(controller.window)
            #expect(nativeWindow.frame.size == NSSize(width: 960, height: 664))
            let session = try #require(controller.viewModel)
            let api = CloudFixtureAPI()
            let login = coordinator(api: api, browser: CloudFixtureBrowser())
            let model = OnboardingCloudModel(session: session, login: login)
            session.cloudModel = model
            session.currentStep = .cloud
            await model.start()
            #expect(model.phase == .waiting)
            controller.window?.close()
            #expect(model.phase == .cancelled && !model.isBusy)
            #expect(controller.window == nil && controller.viewModel == nil)
            #expect(OnboardingCloudModel.activeLogin == nil && OnboardingCloudModel.activeSession == nil)
        }
    }

    @Test func `route controls ignore clicks after navigating away`() async throws {
        try await TestUI.withFixture { settings in
            let session = session(settings, auth: auth())
            session.currentStep = .route
            try await TestUI.withWindow(OnboardingRoutePage(viewModel: session, model: session.routeModel),
                                        width: 960, height: 550) { _, host in
                try TestUI.button(OnboardingStrings.text("customTitle", table: "OnboardingRoute"), in: host).press()
                session.advance()
                #expect(session.currentStep == .speech)
                try TestUI.button("Typeflux Cloud", in: host).press()
                #expect(session.currentStep == .speech && session.serviceRoute == .custom)
            }
        }
    }

    @Test func `background subscription loading hides stale capability actions`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth(paid: false)
            let session = session(settings, auth: state, manager: CloudFixtureManager())
            session.currentStep = .cloud
            let model = session.cloudModel
            try await TestUI.withWindow(OnboardingCloudPage(viewModel: session, model: model),
                                        width: 960, height: 550) { _, host in
                let missing = OnboardingStrings.text("notIncluded", table: "OnboardingCloud")
                let local = OnboardingStrings.text("useLocal", table: "OnboardingCloud")
                try await TestUI.wait { !model.isBusy && TestUI.contains(missing, in: host) }
                state.isLoadingSubscription = true
                defer { state.isLoadingSubscription = false }
                try await TestUI.wait { model.isBusy }
                #expect(model.entitlementReady)
                try await TestUI.wait { !TestUI.contains(missing, in: host) && !TestUI.contains(local, in: host) }
                state.isLoadingSubscription = false
                try await TestUI.wait { TestUI.contains(missing, in: host) }
            }
        }
    }

    @Test func `rendered controls select routes and drive inline browser actions`() async throws {
        try await TestUI.withFixture { settings in
            let state = auth()
            let session = session(settings, auth: state)
            session.currentStep = .route
            for provider in [StudioModelProviderID.openAI, .anthropic, .deepSeek, .gemini, .ollama, .qwen,
                             .openRouter, .doubaoRealtime] {
                #expect(ModelProviderIcon.image(for: provider) != nil)
            }
            try await TestUI.withWindow(OnboardingRoutePage(viewModel: session, model: session.routeModel),
                                        width: 960, height: 550) { _, host in
                try TestUI.button(OnboardingStrings.text("customTitle", table: "OnboardingRoute"), in: host).press()
                #expect(session.serviceRoute == .custom)
                try TestUI.button(OnboardingStrings.text("skipAll"), in: host).press()
                #expect(session.skipConfirmation == .allModels)
                session.skipConfirmation = nil
            }
            state.isLoggedIn = false
            session.chooseRoute(.cloud); session.currentStep = .cloud
            let api = CloudFixtureAPI()
            let browser = CloudFixtureBrowser()
            let model = OnboardingCloudModel(session: session, login: coordinator(api: api, browser: browser))
            try await TestUI.withWindow(OnboardingCloudPage(viewModel: session, model: model),
                                        width: 960, height: 550) { _, host in
                try TestUI.button(OnboardingStrings.text("login", table: "OnboardingCloud"), in: host).press()
                try await TestUI.wait { model.phase == .waiting }
                try await TestUI.wait { TestUI.contains(L("auth.web.reopen"), in: host) }
                try TestUI.button(L("auth.web.reopen"), in: host).press()
                #expect(browser.starts == 2)
                try TestUI.button(L("auth.web.cancel"), in: host).press()
                #expect(model.phase == .cancelled)
            }
            state.isLoggedIn = true
            try await TestUI.withWindow(OnboardingCloudPage(viewModel: session, model: model),
                                        width: 960, height: 550) { _, host in
                let title = OnboardingStrings.text("switchAccount", table: "OnboardingCloud")
                try await TestUI.wait { TestUI.contains(title, in: host) }
                try TestUI.button(title, in: host).press()
                try await TestUI.wait { model.phase == .waiting && !state.isLoggedIn }
                #expect(model.canContinue == false && state.userProfile == nil)
            }
        }
    }

    // The capture matrix deliberately keeps every prototype state together.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @Test func `native route and cloud states render in both languages and appearances`() async throws {
        try await TestUI.withFixture { settings in
            let previousIcon = NSApp.applicationIconImage
            NSApp.applicationIconImage = HelpAppIcon.image
            defer { NSApp.applicationIconImage = previousIcon }
            for language in [AppLanguage.english, .simplifiedChinese] {
                AppLocalization.shared.setLanguage(language)
                settings.appLanguage = language
                for dark in [false, true] {
                    for route in [OnboardingViewModel.ServiceRoute.cloud, .custom] {
                        let state = auth()
                        state.isLoggedIn = false
                        let session = session(settings, auth: state)
                        session.currentStep = .route
                        session.chooseRoute(route)
                        try await capture(session, dark: dark, name: "route-\(route.rawValue)")
                        if route == .cloud {
                            try await withNativeWindow(session, dark: dark) { window, _ in
                                session.requestSetupSkip()
                                try await TestUI.wait { window.attachedSheet != nil }
                                // Wait for the native sheet's presentation animation before caching its pixels.
                                try await Task.sleep(for: .milliseconds(500))
                                let sheet = try #require(window.attachedSheet)
                                sheet.displayIfNeeded()
                                try TestUI.snapshotNativeWindow(
                                    window, overlays: [sheet],
                                    name: "route-skip-\(language.rawValue)-\(dark ? "dark" : "light")"
                                )
                            }
                        }
                    }
                    for kind in [
                        "idle",
                        "creating",
                        "waiting",
                        "exchanging",
                        "failed",
                        "disabled",
                        "cancelled",
                        "paid",
                        "entitlement-loading",
                        "entitlement-failed",
                        "free",
                        "download",
                        "download-failed",
                        "local"
                    ] {
                        print("Native Cloud capture: \(kind), \(language.rawValue), \(dark ? "dark" : "light")")
                        settings.sttProvider = .typefluxOfficial
                        var pendingEntitlement: CheckedContinuation<BillingSubscriptionSnapshot, Never>?
                        let fetch: ((
                            String
                        ) async throws -> BillingSubscriptionSnapshot)? = kind == "entitlement-loading"
                            ? { _ in await withCheckedContinuation { pendingEntitlement = $0 } } : nil
                        let state = auth(paid: kind == "paid", fails: kind == "entitlement-failed", fetch: fetch)
                        let manager = CloudFixtureManager()
                        let session = session(settings, auth: state, manager: manager)
                        session.currentStep = .cloud
                        let api = CloudFixtureAPI()
                        let login = coordinator(api: api, browser: CloudFixtureBrowser(), enabled: kind != "disabled")
                        let model = OnboardingCloudModel(session: session, login: login)
                        session.cloudModel = model
                        defer {
                            model.deactivate()
                            manager.continuation?.resume(); manager.continuation = nil
                            api.exchangeContinuation?.resume(); api.exchangeContinuation = nil
                            api.createContinuation?.resume(); api.createContinuation = nil
                            pendingEntitlement?.resume(returning: .none); pendingEntitlement = nil
                        }
                        if [
                            "paid",
                            "free",
                            "download",
                            "download-failed",
                            "local",
                            "entitlement-failed",
                            "entitlement-loading"
                        ].contains(kind) {
                            model.refresh()
                            try await TestUI
                                .wait { model.entitlementReady || model.error != nil || pendingEntitlement != nil }
                            if kind == "download" {
                                manager.paused = true
                                model.downloadLocalModel()
                                try await TestUI.wait { manager.continuation != nil }
                            }
                            if kind == "local" {
                                model.downloadLocalModel()
                                try await TestUI.wait { model.localReady }
                            }
                        } else {
                            state.isLoggedIn = false
                            if kind == "failed" {
                                api.fail = true
                            }
                            if kind == "creating" {
                                api.pauseCreate = true
                                Task { await model.start() }
                                try await TestUI.wait { api.createContinuation != nil }
                            } else if kind != "idle" {
                                await model.start()
                            }
                            if kind == "cancelled" {
                                model.cancel()
                            }
                            if kind == "exchanging" {
                                api.pauseExchange = true
                                Task { await login.receive(callback) }
                                try await TestUI.wait { model.phase == .exchanging }
                            }
                        }
                        try await capture(session, dark: dark, name: "cloud-\(kind)") { host in
                            if kind == "download-failed" {
                                try await TestUI.wait { model.entitlementReady && !model.isBusy }
                                manager.failure = true
                                model.downloadLocalModel()
                                try await TestUI.wait { model.error != nil }
                                let error = try #require(model.error)
                                try await TestUI.wait { TestUI.contains(error, in: host) }
                            }
                        }
                        await Task.yield()
                    }
                }
            }
        }
    }

    private func capture(_ session: OnboardingViewModel, dark: Bool, name: String,
                         prepare: ((NSView) async throws -> Void)? = nil) async throws {
        try await withNativeWindow(session, dark: dark) { _, host in
            try await prepare?(host)
            #expect(TestUI.contains(session.currentStep == .route ? "Typeflux Cloud" : modelTitle, in: host))
            try TestUI.snapshot(
                #require(host.superview),
                name: "\(name)-\(AppLocalization.shared.language.rawValue)-\(dark ? "dark" : "light")"
            )
        }
    }

    private func withNativeWindow(_ session: OnboardingViewModel, dark: Bool,
                                  check: (NSWindow, NSView) async throws -> Void) async throws {
        let width = OnboardingWindowController.windowWidth
        let height = OnboardingWindowController.windowHeight
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: OnboardingView(viewModel: session, appearanceMode: dark ? .dark : .light)
            .frame(width: width, height: height).ignoresSafeArea())
        host.sizingOptions = []
        window.isReleasedWhenClosed = false
        window.title = L("onboarding.window.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet); sheet.close()
            }
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        try await TestUI.wait { !TestUI.elements(in: host).isEmpty && host.bounds.width > 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        try await check(window, host)
    }

    private var modelTitle: String {
        OnboardingStrings.text("title", table: "OnboardingCloud")
    }

    private var callback: URL {
        URL(
            string: "ai.gulu.app.typeflux://auth/callback?code=\(String(repeating: "a", count: 43))&state=\(String(repeating: "s", count: 43))"
        )!
    }

    private func coordinator(api: CloudFixtureAPI, browser: CloudFixtureBrowser, enabled: Bool = true,
                             accept: @escaping (LoginResponse, Int) async throws -> Void = { _, _ in })
        -> WebLoginCoordinator {
        WebLoginCoordinator(
            configuration: .resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": enabled ? "true" : "false"], info: [:]),
            api: api,
            store: WebLoginMemoryStore(),
            browserFactory: { _, _, _ in browser },
            makeProof: { .init(state: String(repeating: "s", count: 43),
                               verifier: String(repeating: "v", count: 43)) },
            authGeneration: { 0 },
            accept: accept
        )
    }
}

@MainActor
private final class CloudFixtureAPI: WebLoginAPI {
    var fail = false
    var pauseCreate = false
    var createContinuation: CheckedContinuation<Void, Never>?
    var exchanges = 0
    var exchangeFailure: WebLoginFailure?
    var pauseExchange = false
    var exchangeContinuation: CheckedContinuation<Void, Never>?
    func create(proof _: WebLoginProof) async throws -> WebLoginTransaction {
        if pauseCreate {
            await withCheckedContinuation { createContinuation = $0 }
        }
        if fail {
            throw WebLoginFailure.browserUnavailable
        }
        let id = String(repeating: "a", count: 43)
        return .init(transactionID: id, loginURL: "https://typeflux.app/login?transaction=\(id)",
                     expiresAt: Date().timeIntervalSince1970 + 600)
    }

    func exchange(code _: String, verifier _: String) async throws -> LoginResponse {
        exchanges += 1
        if let exchangeFailure {
            throw exchangeFailure
        }
        if pauseExchange {
            await withCheckedContinuation { exchangeContinuation = $0 }
        }
        return .init(
            accessToken: "fixture",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            refreshToken: "fixture"
        )
    }
}

@MainActor
private final class CloudFixtureBrowser: WebLoginBrowserSession {
    var starts = 0
    func start() -> Bool {
        starts += 1; return true
    }

    func cancel() {}
}

private final class CloudFixtureManager: LocalSTTModelManaging, @unchecked Sendable {
    private struct State {
        var preparations = 0
        var available = false
        var failure = false
        var paused = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()
    var preparations: Int {
        get { lock.withLock { state.preparations } }
        set { lock.withLock { state.preparations = newValue } }
    }

    var available: Bool {
        get { lock.withLock { state.available } }
        set { lock.withLock { state.available = newValue } }
    }

    var failure: Bool {
        get { lock.withLock { state.failure } }
        set { lock.withLock { state.failure = newValue } }
    }

    var paused: Bool {
        get { lock.withLock { state.paused } }
        set { lock.withLock { state.paused = newValue } }
    }

    var continuation: CheckedContinuation<Void, Never>? {
        get { lock.withLock { state.continuation } }
        set { lock.withLock { state.continuation = newValue } }
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        try await prepareModel(configuration: .init(settingsStore: settingsStore), onUpdate: onUpdate)
    }

    func prepareModel(configuration _: LocalSTTConfiguration,
                      onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?) async throws {
        preparations += 1
        onUpdate?(.init(message: "", progress: 0.58, storagePath: "", source: nil))
        if failure {
            throw URLError(.notConnectedToInternet)
        }
        if paused {
            await withCheckedContinuation { continuation = $0 }
        }
        available = true
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        available
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}
    func storagePath(for _: LocalSTTConfiguration) -> String {
        ""
    }
}

@MainActor
private final class CloudFixturePrompt: CloudModelDefaultsPrompting {
    var calls = 0
    func confirmSwitchToCloudDefaults() -> Bool {
        calls += 1; return false
    }

    func showCloudDefaultsApplied() {
        calls += 1
    }

    func confirmSwitchToCloudLLMDefault() -> Bool {
        calls += 1; return false
    }

    func showCloudLLMDefaultApplied() {
        calls += 1
    }
}
