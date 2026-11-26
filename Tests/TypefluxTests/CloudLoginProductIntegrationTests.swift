import AppKit
@testable import Typeflux
import XCTest

extension CloudLoginSyncCoordinatorTests {
    func testCaptureNativeCloudSwitchConfirmation() async throws {
        guard CloudSpeechAcceptanceCapture.enabled else { throw XCTSkip("Screenshot capture is opt-in") }
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        let auth = makeAuthState(subscription: activeSubscription())
        let app = NSApplication.shared
        let originalLanguage = AppLocalization.shared.language
        let originalPolicy = app.activationPolicy()
        let originalAppearance = app.appearance
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        // Match the host app so AppKit draws the active default button.
        XCTAssertTrue(app.setActivationPolicy(.accessory))
        app.appearance = NSAppearance(named: .darkAqua)
        defer {
            app.appearance = originalAppearance
            app.setActivationPolicy(originalPolicy)
            AppLocalization.shared.setLanguage(originalLanguage)
        }
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: auth)
        let activationDeadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let window = app.modalWindow, let content = window.contentView else { return }
                if !app.isActive || !window.isKeyWindow {
                    if Date() < activationDeadline { return }
                    timer.invalidate()
                    XCTFail("The confirmation did not become the active window")
                    app.stopModal(withCode: .alertSecondButtonReturn)
                    return
                }
                timer.invalidate()
                do {
                    let button = try XCTUnwrap(window.defaultButtonCell?.controlView as? NSButton)
                    XCTAssertEqual(button.title, L("cloud.subscriptionSwitch.confirm"))
                    XCTAssertEqual(button.keyEquivalent, "\r")
                    try CloudSpeechAcceptanceCapture.save(content.superview ?? content, name: "01-switch")
                    button.performClick(nil)
                } catch {
                    XCTFail("Could not capture the Cloud confirmation: \(error)")
                    app.stopModal(withCode: .alertSecondButtonReturn)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        await signIn(auth)
        for _ in 0..<30 where settings.sttProvider != .typefluxOfficial {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.rewriteModelReference, "cloud:default")
        withExtendedLifetime(coordinator) {}
    }

    func testSwitchingSpeechPreservesAnExistingCloudRewriteModel() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        let rewriteModel = AskCloudModel(id: "chosen-rewrite", name: "Chosen Rewrite", scenarios: ["rewrite"])
        settings.defaults.set(try JSONEncoder().encode([rewriteModel]), forKey: AskModelLibrary.rewriteCatalogKey)
        settings.defaults.set(rewriteModel.reference, forKey: "llm.profile.reference")
        let state = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt,
                                                    languageProvider: { $0.effectiveLLMProvider })

        await signIn(state)
        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.rewriteModelReference, rewriteModel.reference)
        XCTAssertEqual(settings.textLLMConfiguration().provider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }
}
