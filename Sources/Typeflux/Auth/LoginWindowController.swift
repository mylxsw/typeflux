import AppKit

@MainActor
final class LoginWindowController {
    static let shared = LoginWindowController()

    private lazy var webEntry = WebLoginEntryController(
        coordinator: AuthState.shared.webLoginCoordinator,
        reportFailure: { failure in
            guard Self.shouldPresentWebLoginAlerts else { return }
            let alert = NSAlert()
            alert.messageText = L("auth.login.windowTitle")
            alert.informativeText = L(failure.localizationKey)
            alert.alertStyle = .warning
            alert.runModal()
        },
        reportSuccess: {
            guard Self.shouldPresentWebLoginAlerts else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = Self.makeLoginSuccessAlert()
            alert.runModal()
        }
    )

    static var shouldPresentWebLoginAlerts: Bool {
        OnboardingCloudModel.activeSession == nil
    }

    static func makeLoginSuccessAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("auth.web.successTitle")
        alert.informativeText = L("auth.web.successMessage")
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
        return alert
    }

    func show() {
        guard FeatureProcess.owns(.host) else {
            FeatureProcess.send(.init(destination: .host, action: "login")); return
        }
        if let session = OnboardingCloudModel.activeSession, session.currentStep == .cloud {
            let model = session.cloudModel
            if model.phase == .waiting {
                model.reopen()
            } else {
                Task { await model.start() }
            }
            return
        }
        webEntry.show()
    }

    func showWebLoginFailure() { webEntry.showCurrentFailure() }
}
