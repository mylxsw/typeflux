// swiftlint:disable file_length
import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux
import UserNotifications

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingPermissionsTests {
    private typealias TestUI = SettingsBehaviorTestSupport

    // swiftlint:disable:next function_body_length
    @Test func `required permissions follow route and provider and optional permissions never gate`() async throws {
        try await TestUI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let probe = OnboardingPermissionProbe()
            let model = probe.model(session)
            session.permissionsModel = model
            session.currentStep = .permissions
            session.permissions = PrivacyGuard.PermissionID.allCases.map {
                .init(id: $0, state: .granted, detail: "Previously granted")
            }
            #expect(model.canContinue == false && !session.canAdvance)
            session.serviceRoute = .custom
            settings.sttProvider = .whisperAPI
            await model.refresh()
            #expect(model.required == [.microphone, .accessibility])
            #expect(model.optional.count == 6)
            #expect(model.optionalGranted == 0)
            #expect(model.nextPending == .microphone && model.canContinue == false)
            #expect(!session.canAdvance)
            #expect(model.footerHint != nil)
            probe.statuses[.microphone] = .granted
            await model.refresh()
            #expect(model.requiredGranted == 1 && model.nextPending == .accessibility)
            settings.sttProvider = .appleSpeech
            await model.refresh()
            #expect(model.required == [.microphone, .accessibility, .speechRecognition])
            probe.statuses[.accessibility] = .granted
            await model.refresh()
            #expect(model.nextPending == .speechRecognition)
            probe.statuses[.speechRecognition] = .granted
            await model.refresh()
            #expect(model.requiredGranted == 3 && model.nextPending == nil)
            #expect(model.footerHint == nil)
            let allGranted = session.permissions.allSatisfy(\.isGranted)
            #expect(allGranted)
            #expect(session.canAdvance)
            settings.onboardingPermissionsDeferred = true
            session.advance()
            #expect(session.currentStep == .shortcuts)
            #expect(!settings.onboardingPermissionsDeferred)
            session.serviceRoute = .launcherOnly
            probe.statuses[.microphone] = .notGranted
            probe.statuses[.speechRecognition] = .notGranted
            await model.refresh()
            #expect(model.required == [.accessibility] && model.canContinue == true)
            session.currentStep = .permissions
            session.skipPermissions()
            session.confirmSkip()
            #expect(settings.onboardingPermissionsDeferred)
            #expect(session.currentStep == .shortcuts)
            model.session = nil
            await model.refresh()
            #expect(model.required.isEmpty && model.canContinue == false)
        }
    }

    @Test func `requests switch denied actions to settings and guide tracks external grants`() async throws {
        try await TestUI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let probe = OnboardingPermissionProbe()
            let model = probe.model(session)
            await model.refresh()
            await model.request(.microphone)
            #expect(probe.requests == [.microphone])
            #expect(model.guidePermission == nil)
            #expect(model.settingsActions.contains(.microphone))
            await model.request(.microphone)
            #expect(model.guidePermission == .microphone)
            probe.statuses[.microphone] = .granted
            await model.refresh()
            #expect(model.status(.microphone) == .granted)
            model.dismissGuide()
            #expect(model.guidePermission == nil)
            await model.request(.microphone)
            #expect(probe.requests.count == 2)
            await model.request(.screenRecording)
            #expect(model.guidePermission == .screenRecording)
            let polling = Task { await model.monitorGuide() }
            probe.statuses[.screenRecording] = .granted
            try await TestUI.wait { model.status(.screenRecording) == .granted }
            #expect(model.optionalGranted == 1)
            polling.cancel()
            await polling.value
            model.stop()
            #expect(model.guidePermission == nil && !model.isBusy)
            await model.monitorGuide()
            probe.failRequest = true
            await model.request(.camera)
            #expect(model.permissions.requestError == .camera)
            #expect(!model.isBusy)
            model.requestAccess(.calendar)
            model.requestAccess(.notifications)
            try await TestUI.wait { !model.isBusy && probe.requests.last == .calendar }
            #expect(!probe.requests.contains(.notifications))
            model.requestAccess(.notifications)
            model.stop()
            try await Task.sleep(for: .milliseconds(20))
            #expect(!model.isBusy)
        }
    }

    @Test func `required statuses gate continuation independently of pending optional queries`() async throws {
        try await TestUI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let probe = OnboardingPermissionProbe()
            let model = probe.model(session)
            session.permissionsModel = model
            session.currentStep = .permissions
            probe.statuses[.microphone] = .granted
            probe.statuses[.accessibility] = .granted
            settings.sttProvider = .whisperAPI
            await model.refresh()
            #expect(session.canAdvance)
            probe.pauseStatus = .calendar
            let optionalRefresh = Task { await model.refresh() }
            try await TestUI.wait { probe.resumeStatus != nil }
            #expect(session.canAdvance)
            probe.resumeStatus?.resume()
            probe.resumeStatus = nil
            await optionalRefresh.value
            probe.statuses[.microphone] = .notGranted
            let refresh = Task { await model.refresh() }
            try await TestUI.wait { probe.resumeStatus != nil }
            #expect(model.nextPending == .microphone && !session.canAdvance)
            probe.pauseStatus = nil
            probe.resumeStatus?.resume()
            probe.resumeStatus = nil
            await refresh.value
            #expect(!session.canAdvance)
        }
    }

    @Test func `leaving the page cancels requests and suppresses late guide updates`() async throws {
        try await TestUI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let probe = OnboardingPermissionProbe()
            let model = probe.model(session)
            await model.refresh()
            probe.pauseRequest = true
            model.requestAccess(.screenRecording)
            try await TestUI.wait { probe.resumeRequest != nil }
            await model.request(.camera)
            let reads = probe.statusReads
            await model.refresh()
            #expect(probe.statusReads == reads)
            #expect(probe.requests == [.screenRecording])
            model.stop()
            probe.resumeRequest?.resume()
            probe.resumeRequest = nil
            try await TestUI.wait { !model.isBusy }
            #expect(model.guidePermission == nil)
            let refresh = Task { await model.refresh() }
            refresh.cancel()
            await refresh.value
        }
    }
}

extension OnboardingPermissionsTests {
    @Test func `system adapter selects native prompts and pane navigation without external guidance`() async throws {
        var dialogs: [PrivacyGuard.PermissionID] = []
        var opened: [URL] = []
        var promptedAX = 0
        var showsDialog = true
        var camera: AVAuthorizationStatus = .notDetermined
        var calendar: CalendarAccess = .unknown
        var notifications: UNAuthorizationStatus? = .notDetermined
        let screen = OnboardingScreenPermissionProbe()
        let adapters = SettingsPermissionSystem(
            coreGranted: { _ in false }, requestCore: { _ in }, screenCapture: screen,
            cameraAuthorization: { camera }, requestCamera: {}, calendarAccess: { calendar },
            requestCalendar: {}, notificationAuthorization: { notifications }, requestNotifications: {},
            fullDiskAccessGranted: { false }, openURL: { _ in }
        )
        let system = OnboardingPermissionsSystem(
            adapters: adapters, showsDialog: { _ in showsDialog }, requestDialog: { dialogs.append($0) },
            promptAccessibility: { promptedAX += 1 }, openURL: { opened.append($0) }
        )
        for permission in SettingsPermission.allCases {
            let hasPrompt = permission.corePermission != nil || [.camera, .calendar, .notifications]
                .contains(permission)
            #expect(await system.opensSettings(permission) == !hasPrompt)
        }
        try await system.service.request(.microphone)
        #expect(dialogs == [.microphone])
        showsDialog = false
        camera = .denied; calendar = .denied; notifications = .denied
        for permission in SettingsPermission.allCases {
            #expect(await system.opensSettings(permission))
        }
        try await system.service.request(.accessibility)
        try await system.service.request(.microphone)
        try await system.service.request(.camera)
        #expect(promptedAX == 1)
        #expect(opened == [SettingsPermission.accessibility.settingsURL, SettingsPermission.microphone.settingsURL,
                           SettingsPermission.camera.settingsURL])
        #expect(await system.service.status(.automation) == .systemManaged)
    }

    // The matrix intentionally covers each prototype state in both languages and appearances.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @Test func `permissions states render in Chinese and English in both appearances`() async throws {
        try await TestUI.withFixture { settings in
            for language in [AppLanguage.english, .simplifiedChinese] {
                settings.appLanguage = language
                AppLocalization.shared.setLanguage(language)
                for dark in [false, true] {
                    for state in ["initial", "denied", "accessibility-guide", "complete", "optional",
                                  "optional-guide", "guide-complete", "automation-guide", "apple-speech", "launcher"] {
                        let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
                        session.serviceRoute = state == "launcher" ? .launcherOnly : .custom
                        session.currentStep = .permissions
                        settings.sttProvider = state == "apple-speech" ? .appleSpeech : .whisperAPI
                        let probe = OnboardingPermissionProbe()
                        let model = probe.model(session)
                        session.permissionsModel = model
                        if ["accessibility-guide", "complete", "optional", "optional-guide"].contains(state) {
                            probe.statuses[.microphone] = .granted
                        }
                        if ["complete", "optional", "optional-guide"].contains(state) {
                            probe.statuses[.accessibility] = .granted
                        }
                        if state == "denied" {
                            probe.settings.insert(.microphone)
                        }
                        model.optionalExpanded = ["optional", "optional-guide"].contains(state)
                        if state == "optional" {
                            probe.statuses[.calendar] = .granted
                        }
                        await model.refresh()
                        if state == "accessibility-guide" {
                            await model.request(.accessibility)
                        }
                        if state == "optional-guide" {
                            await model.request(.screenRecording)
                        }
                        if state == "guide-complete" {
                            await model.request(.accessibility)
                            probe.statuses[.accessibility] = .granted
                            await model.refresh()
                        }
                        if state == "automation-guide" {
                            await model.request(.automation)
                        }
                        try await withPermissionWindow(session, dark: dark) { window, host in
                            try await Task.sleep(for: .milliseconds(100))
                            #expect(TestUI.contains(OnboardingPermissionsPage.text("title"), in: host))
                            #expect(TestUI.contains("02 / 04", in: host))
                            if state == "initial" {
                                let toggle = try #require(TestUI.elements(in: host).first {
                                    $0.value("accessibilityIdentifier") as? String == "onboarding.permissions.optional"
                                })
                                try toggle.press()
                                #expect(model.optionalExpanded)
                                try toggle.press()
                                #expect(!model.optionalExpanded)
                            }
                            if state == "complete" {
                                #expect(model.canContinue == true)
                                let next = try TestUI.button(OnboardingStrings.text("continue"), in: host)
                                #expect(next.value("isAccessibilityEnabled") as? Bool == true)
                            }
                            let nativeFrame = try #require(window.contentView?.superview)
                            try TestUI.snapshot(
                                nativeFrame,
                                name: "permissions-\(state)-\(language.rawValue)-\(dark ? "dark" : "light")"
                            )
                            if state == "optional" {
                                let scroll = try #require(scrollViews(in: host).first)
                                let document = try #require(scroll.documentView)
                                let bottom = document.isFlipped
                                    ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                try await Task.sleep(for: .milliseconds(50))
                                try TestUI.snapshot(
                                    nativeFrame,
                                    name: "permissions-optional-bottom-\(language.rawValue)-\(dark ? "dark" : "light")"
                                )
                            }
                            if state == "initial" {
                                try TestUI.button(OnboardingPermissionsPage.text("allow"), in: host).press()
                                try await TestUI.wait { probe.requests == [.microphone] && !model.isBusy }
                            }
                            if model.guidePermission != nil {
                                try TestUI.button("×", in: host).press()
                                #expect(model.guidePermission == nil)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension OnboardingPermissionsTests {
    private func withPermissionWindow(_ session: OnboardingViewModel, dark: Bool,
                                      check: (NSWindow, NSView) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 960, height: 664),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: OnboardingView(viewModel: session, appearanceMode: dark ? .dark : .light)
            .interfaceStyle(following: InterfaceStyleObserver(settings: session.settingsStore))
            .frame(width: 960, height: 664).ignoresSafeArea())
        host.sizingOptions = []
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = AppAppearance.nsAppearance(for: dark ? .dark : .light)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        try await TestUI.wait { !TestUI.elements(in: host).isEmpty && host.bounds.width > 0 }
        host.layoutSubtreeIfNeeded()
        try await check(window, host)
    }

    @Test func `returning during a canceled native request refreshes its late grant without advancing`() async throws {
        try await TestUI.withFixture { settings in
            settings.sttProvider = .whisperAPI
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let probe = OnboardingPermissionProbe()
            let model = probe.model(session)
            session.permissionsModel = model
            session.currentStep = .permissions
            try await withPermissionWindow(session, dark: false) { _, host in
                try await TestUI.wait { !model.permissions.isRefreshing }
                probe.pauseRequest = true
                model.requestAccess(.microphone)
                try await TestUI.wait { probe.resumeRequest != nil }
                session.currentStep = .shortcuts
                try await TestUI.wait {
                    TestUI.contains(OnboardingStrings.text("title", table: "OnboardingShortcuts"), in: host)
                }
                session.currentStep = .permissions
                try await TestUI.wait { TestUI.contains(OnboardingPermissionsPage.text("title"), in: host) }
                probe.statuses[.microphone] = .granted
                probe.statuses[.accessibility] = .granted
                probe.pauseRequest = false
                probe.resumeRequest?.resume()
                probe.resumeRequest = nil
                try await TestUI.wait { model.canContinue == true }
                #expect(model.guidePermission == nil && session.currentStep == .permissions)
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func `page copy resolves in all five languages`() {
        for language in AppLanguage.allCases {
            for permission in SettingsPermission.allCases {
                for suffix in ["title", "summary"] {
                    let key = "\(permission.rawValue).\(suffix)"
                    #expect(OnboardingStrings.text(key, table: "OnboardingPermissions", language: language) != key)
                }
            }
            for key in ["required", "optional", "optionalHint", "allow", "openSettings", "granted", "managed",
                        "waiting", "denied", "guideTitle", "guideOtherApp", "completed", "detecting"] {
                #expect(OnboardingStrings.text(key, table: "OnboardingPermissions", language: language) != key)
            }
        }
    }
}

@MainActor
private final class OnboardingPermissionProbe {
    var statuses: [SettingsPermission: SettingsPermissionStatus] = [.automation: .systemManaged]
    var settings: Set<SettingsPermission> = [.accessibility, .automation, .fullDiskAccess]
    var requests: [SettingsPermission] = []
    var statusReads = 0
    var pauseStatus: SettingsPermission?
    var resumeStatus: CheckedContinuation<Void, Never>?
    var failRequest = false
    var pauseRequest = false
    var resumeRequest: CheckedContinuation<Void, Never>?
    enum Failure: Error { case denied }

    func model(_ session: OnboardingViewModel) -> OnboardingPermissionsModel {
        let service = SettingsPermissionService(status: {
            self.statusReads += 1
            if self.pauseStatus == $0 {
                await withCheckedContinuation { self.resumeStatus = $0 }
            }
            return self.statuses[$0] ?? .notGranted
        }, request: {
            self.requests.append($0)
            if self.pauseRequest {
                await withCheckedContinuation { self.resumeRequest = $0 }
            }
            self.settings.insert($0)
            if self.failRequest {
                throw Failure.denied
            }
        })
        return OnboardingPermissionsModel(session: session, service: service,
                                          opensSettings: { self.settings.contains($0) })
    }
}

private final class OnboardingScreenPermissionProbe: ScreenCapturePermissionProviding {
    var isGranted = false
    func request() -> Bool {
        false
    }

    func requestOnce() {}
    func openSystemSettings() {}
}
