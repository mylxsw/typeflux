import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Exercises the production capture service with only operating-system calls replaced.
@MainActor
final class ScreenshotPermissionProbe {
    var allowed = false
    var grantsRequest = false
    var requests = 0
    var captures = 0
    lazy var capture = AskContextCapture(
        injector: ContextTextInjector(),
        preflightScreenCapture: { [weak self] in self?.allowed ?? false },
        requestScreenCapture: { [weak self] in
            guard let self else { return false }
            requests += 1
            allowed = grantsRequest
            return allowed
        },
        accessibilityTrusted: { false }, frontmostProcessID: { 42 },
        captureScreenshot: { [weak self] _ in
            guard let self else { throw CancellationError() }
            captures += 1
            return "image"
        }
    )
}

@Suite("Screenshot permission opt-in", .exclusiveUIState)
@MainActor
struct AskScreenshotPermissionTests {
    private final class InputSource: AskLauncherInputSourceSelecting {
        func selectEnglish() {}
    }

    @Test func openingTheNativeLauncherNeverRequestsDeniedAccess() async throws {
        _ = NSApplication.shared
        let keychain = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = keychain
        let probe = ScreenshotPermissionProbe()
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        fixture.model.appIndex = AskTestAppIndex([])
        let suite = "gul294-launcher-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults),
            model: fixture.model, launcherInputSource: InputSource())
        defer {
            controller.dismissLauncher()
            fixture.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
        controller.showLauncher()
        try await fixture.wait { fixture.model.launcherDraft.capturedAt != nil && !fixture.model.capturing }
        #expect(controller.launcherWindow?.isVisible == true)
        #expect(!fixture.model.launcherDraft.includeScreenshot)
        #expect(probe.captures == 0 && probe.requests == 0)
        print("GUL-294 production showLauncher: denied access, captures=0, permissionRequests=0")
    }

    @Test(arguments: [false, true]) func firstQuestionsUseReadOnlyPermission(_ allowed: Bool) async throws {
        let probe = ScreenshotPermissionProbe()
        probe.allowed = allowed
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        #expect(fixture.model.launcherDraft.includeScreenshot == allowed)
        #expect(probe.capture.missingScreenshotWarning() == L(allowed ? "ask.capture.unavailable" : "ask.capture.permission"))
        await fixture.model.prepareLauncher()
        #expect(fixture.model.launcherDraft.includeScreenshot == allowed)
        #expect(probe.requests == 0)
        #expect(probe.captures == (allowed ? 1 : 0))
        fixture.model.newConversation()
        #expect(fixture.model.draft.includeScreenshot == allowed)
        #expect(!AskDraft.followUp.includeScreenshot)
        #expect(probe.requests == 0)
        print("GUL-294 production prepareLauncher: allowed=\(allowed), captures=\(probe.captures), permissionRequests=\(probe.requests)")
    }

    @Test func revokedAccessDoesNotCaptureOnReopen() async throws {
        let probe = ScreenshotPermissionProbe()
        probe.allowed = true
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        probe.allowed = false
        await fixture.model.prepareLauncher()
        #expect(!fixture.model.launcherDraft.includeScreenshot)
        #expect(fixture.model.launcherDraft.screenshot == nil)
        #expect(probe.captures == 1 && probe.requests == 0)
        let context = await probe.capture.capture(includeScreenshot: true, includeSelection: false)
        #expect(context.screenshot == nil && context.warning == L("ask.capture.permission"))
        #expect(probe.captures == 1 && probe.requests == 0)
    }

    @Test(arguments: [true, false], ["toggle", "command", "suggestion", "suggestionCommand"])
    func explicitEntryRequestsAccessAndKeepsDraft(_ launcher: Bool, _ entry: String) async throws {
        let probe = ScreenshotPermissionProbe()
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        fixture.model.newConversation()
        fixture.model.launcherDraft.text = "Keep my question"
        fixture.model.draft.text = "Keep my question"
        switch entry {
        case "toggle":
            fixture.model.restoreCapturedContent(.screenshot, launcher: launcher)
            await fixture.model.refreshScreenshot(launcher: launcher)
        case "command":
            let command = try #require(AskCommandCatalog.commands(fixture.model.commandContext(launcher: launcher)).first { $0.name == "screenshot" })
            fixture.model.runCommand(command, launcher: launcher)
        case "suggestionCommand":
            let command = try #require(AskCommandCatalog.commands(fixture.model.commandContext(launcher: launcher))
                .first { $0.name == "explain-screen" })
            fixture.model.runCommand(command, launcher: launcher)
        default:
            fixture.model.attachScreenshotForSuggestion(launcher: launcher)
        }
        try await fixture.wait { probe.requests == 1 }
        let draft = launcher ? fixture.model.launcherDraft : fixture.model.draft
        #expect(draft.includeScreenshot && draft.screenshot == nil)
        #expect(draft.text.contains("Keep my question"))
        #expect(fixture.model.captureWarning == L("ask.capture.permission"))
        #expect(fixture.model.capturedContentChanges[launcher] == nil)
        #expect(probe.captures == 0)
        if launcher {
            await fixture.model.prepareLauncher()
            #expect(fixture.model.captureWarning == L("ask.capture.permission"))
            #expect(probe.requests == 1 && probe.captures == 0)
        }
    }

    @Test func grantingAccessCapturesAndClearsWarning() async throws {
        let probe = ScreenshotPermissionProbe()
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        fixture.model.restoreCapturedContent(.screenshot, launcher: true)
        await fixture.model.refreshScreenshot(launcher: true)
        probe.grantsRequest = true
        await fixture.model.refreshScreenshot(launcher: true)
        #expect(fixture.model.launcherDraft.screenshot == "image")
        #expect(fixture.model.captureWarning == nil)
        #expect(probe.requests == 2 && probe.captures == 1)
        await fixture.model.refreshScreenshot(launcher: true)
        #expect(probe.requests == 2 && probe.captures == 2)
    }

    @Test func renderPermissionSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let probe = ScreenshotPermissionProbe()
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        fixture.model.newConversation()
        fixture.model.launcherDraft.text = "帮我解释这段内容"
        fixture.model.draft.text = "帮我解释这段内容"
        for enabled in [false, true] {
            if enabled {
                fixture.model.restoreCapturedContent(.screenshot, launcher: true)
                await fixture.model.refreshScreenshot(launcher: true)
                fixture.model.restoreCapturedContent(.screenshot, launcher: false)
                await fixture.model.refreshScreenshot(launcher: false)
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for launcher in [true, false] {
                    try await AskConversationVisualTests().render(
                        AskComposer(model: fixture.model, launcher: launcher, onDismiss: {})
                            .padding(12).background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.askGlassMaterialOverride, .opaque),
                        size: NSSize(width: launcher ? 680 : 800, height: 240), appearance: appearance,
                        file: root.appendingPathComponent("\(launcher ? "launcher" : "chat")-\(enabled ? "denied" : "off")-\(name).png"),
                        minimumPNGBytes: 3000)
                }
            }
        }
        #expect(probe.captures == 0 && probe.requests == 2)
    }
}
