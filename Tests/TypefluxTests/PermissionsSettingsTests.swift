import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux
import UserNotifications

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct PermissionsSettingsTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `catalog keeps core permissions separate from feature permissions`() {
        #expect(SettingsPermission.allCases.filter(\.isRequired) == [.microphone, .speechRecognition, .accessibility])
        #expect(SettingsPermission.allCases.filter { !$0.isRequired } == [
            .screenRecording, .camera, .calendar, .notifications, .automation, .fullDiskAccess
        ])
        #expect(AppSettingsPane.allCases == [.general, .appearance, .permissions, .hotkeys, .advanced])
        #expect(AppSettingsPane.permissions.symbol == "lock.shield")
        #expect(AppSettingsPane.permissions.id == "permissions")
        #expect(AppSettingsPane.permissions.title == L("settings.permissions"))
        let panes: [String] = ["Privacy_Microphone", "Privacy_SpeechRecognition", "Privacy_Accessibility",
                               "Privacy_ScreenCapture", "Privacy_Camera", "Privacy_Calendars", "notifications",
                               "Privacy_Automation", "Privacy_AllFiles"]
        for (permission, pane) in zip(SettingsPermission.allCases, panes) {
            #expect(permission.id == permission.rawValue)
            #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
            #expect(permission.settingsURL.absoluteString.hasSuffix(pane))
        }
    }

    @Test func `permission copy is localized in every supported language`() async throws {
        try await UI.withFixture { _ in
            for language in AppLanguage.allCases {
                AppLocalization.shared.setLanguage(language)
                for permission in SettingsPermission.allCases {
                    #expect(!permission.title.isEmpty && !permission.title.hasPrefix("permission."))
                    #expect(!permission.summary.isEmpty && !permission.summary.hasPrefix("permission."))
                }
                for status in [SettingsPermissionStatus.granted, .notGranted, .systemManaged] {
                    #expect(!status.badgeText.hasPrefix("permission."))
                    #expect(!status.actionTitle.hasPrefix("permission."))
                }
                for key in ["settings.permissions.required", "settings.permissions.optional",
                            "settings.permissions.requiredHint", "settings.permissions.optionalHint",
                            "settings.permissions.requestFailed"] {
                    #expect(L(key) != key)
                }
            }
        }
    }

    @Test func `status checks do not request access or open settings`() async {
        let probe = PermissionSystemProbe()
        let service = probe.service
        for granted in [false, true] {
            probe.coreGranted = granted
            probe.screen.granted = granted
            probe.camera = granted ? .authorized : .denied
            probe.calendar = granted ? .allowed : .denied
            probe.notifications = granted ? .authorized : .denied
            probe.diskGranted = granted
            for permission in SettingsPermission.allCases {
                #expect(await service.status(permission) == (permission == .automation ? .systemManaged :
                        granted ? .granted : .notGranted))
            }
        }
        for status: AVAuthorizationStatus in [.notDetermined, .restricted] {
            probe.camera = status
            #expect(await service.status(.camera) == .notGranted)
        }
        probe.calendar = .unknown
        #expect(await service.status(.calendar) == .notGranted)
        probe.notifications = .notDetermined
        #expect(await service.status(.notifications) == .notGranted)
        probe.notifications = .provisional
        #expect(await service.status(.notifications) == .granted)
        probe.notifications = nil
        #expect(await service.status(.notifications) == .systemManaged)
        #expect(probe.requests.isEmpty && probe.opened.isEmpty)
        #expect(probe.screen.requests == 0 && probe.screen.settingsOpened == 0)
    }

    @Test func `requests reuse core and screen capture adapters`() async throws {
        let probe = PermissionSystemProbe()
        let service = probe.service
        for permission in SettingsPermission.allCases.filter(\.isRequired) {
            try await service.request(permission)
        }
        #expect(probe.requests == ["microphone", "speechRecognition", "accessibility"])
        try await service.request(.screenRecording)
        #expect(probe.screen.requests == 1 && probe.screen.settingsOpened == 1)
        probe.screen.grantOnRequest = true
        try await service.request(.screenRecording)
        #expect(probe.screen.requests == 2 && probe.screen.settingsOpened == 1)
        try await service.request(.screenRecording)
        #expect(probe.screen.requests == 2 && probe.screen.settingsOpened == 2)
    }

    @Test func `first time requests and previously decided permissions take the correct route`() async throws {
        let probe = PermissionSystemProbe()
        let service = probe.service
        try await service.request(.camera)
        try await service.request(.calendar)
        try await service.request(.notifications)
        #expect(probe.requests == ["camera", "calendar", "notifications"])
        for status: AVAuthorizationStatus in [.authorized, .denied, .restricted] {
            probe.camera = status
            try await service.request(.camera)
        }
        for access: CalendarAccess in [.allowed, .denied] {
            probe.calendar = access
            try await service.request(.calendar)
        }
        for status: UNAuthorizationStatus? in [.authorized, .denied, .provisional, nil] {
            probe.notifications = status
            try await service.request(.notifications)
        }
        try await service.request(.automation)
        try await service.request(.fullDiskAccess)
        #expect(probe.requests == ["camera", "calendar", "notifications"])
        #expect(probe.opened == Array(repeating: SettingsPermission.camera.settingsURL, count: 3)
            + Array(repeating: SettingsPermission.calendar.settingsURL, count: 2)
            + Array(repeating: SettingsPermission.notifications.settingsURL, count: 4)
            + [SettingsPermission.automation.settingsURL, SettingsPermission.fullDiskAccess.settingsURL])
    }

    @Test func `request failures are visible and later success clears the error`() async {
        let probe = PermissionSystemProbe()
        let model = PermissionsSettingsModel(service: probe.service)
        for permission in [SettingsPermission.calendar, .notifications] {
            probe.failRequest = true
            await model.request(permission)
            #expect(model.requestError == permission)
            #expect(model.requestingPermission == nil && !model.isRefreshing)
            #expect(model.statuses.count == SettingsPermission.allCases.count)
            probe.failRequest = false
            await model.request(permission)
            #expect(model.requestError == nil)
            #expect(model.statuses[permission] == .granted)
        }
    }

    @Test func `refresh coalesces overlaps and blocks requests until statuses are ready`() async throws {
        var reads = 0
        var requests = 0
        var blocked: CheckedContinuation<Void, Never>?
        let model = PermissionsSettingsModel(service: SettingsPermissionService(status: { _ in
            reads += 1
            if reads == 1 {
                await withCheckedContinuation { blocked = $0 }
            }
            return reads > SettingsPermission.allCases.count ? .granted : .notGranted
        }, request: { _ in requests += 1 }))
        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            blocked?.resume()
        }
        try await UI.wait { blocked != nil }
        await model.request(.camera)
        await model.refresh()
        #expect(model.isRefreshing && requests == 0)
        blocked?.resume()
        blocked = nil
        await refresh.value
        #expect(!model.isRefreshing)
        #expect(reads == SettingsPermission.allCases.count * 2)
        #expect(model.statuses.values.allSatisfy { $0 == .granted })
    }

    @Test func `canceled refresh and request release busy state`() async throws {
        var blocked: CheckedContinuation<SettingsPermissionStatus, Never>?
        var shouldBlock = true
        let model = PermissionsSettingsModel(service: SettingsPermissionService(status: { _ in
            if shouldBlock {
                shouldBlock = false
                return await withCheckedContinuation { blocked = $0 }
            }
            return .granted
        }, request: { _ in throw CancellationError() }))
        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            blocked?.resume(returning: .notGranted)
        }
        try await UI.wait { blocked != nil }
        refresh.cancel()
        blocked?.resume(returning: .notGranted)
        blocked = nil
        await refresh.value
        #expect(!model.isRefreshing && model.statuses.isEmpty)
        await model.refresh()
        #expect(model.statuses.count == SettingsPermission.allCases.count)
        await model.request(.calendar)
        #expect(model.requestError == nil && model.requestingPermission == nil)
    }

    @Test func `repeated clicks cannot launch concurrent permission requests`() async throws {
        var requests: [SettingsPermission] = []
        var blocked: CheckedContinuation<Void, Never>?
        let model = PermissionsSettingsModel(service: SettingsPermissionService(status: { _ in .notGranted },
                                                                                request: { permission in
                                                                                    requests.append(permission)
                                                                                    await withCheckedContinuation {
                                                                                        blocked = $0
                                                                                    }
                                                                                }))
        let request = Task { await model.request(.camera) }
        defer {
            request.cancel()
            blocked?.resume()
        }
        try await UI.wait { blocked != nil }
        await model.request(.calendar)
        #expect(requests == [.camera] && model.requestingPermission == .camera)
        blocked?.resume()
        blocked = nil
        await request.value
        #expect(model.requestingPermission == nil)
    }

    @Test func `settings tab moves permissions out of general and before shortcuts`() async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: .settings,
                                        modelLibrary: AskModelLibrary(
                                            defaults: settings.defaults,
                                            automaticallyLoadsCatalog: false
                                        ))
            for width: CGFloat in [720, 1100] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 1200) { _, host in
                    #expect(!UI.contains(L("settings.permissionStatus.title"), in: host))
                    let appearance = try UI.button(AppSettingsPane.appearance.title, in: host)
                    let permissions = try UI.button(AppSettingsPane.permissions.title, in: host)
                    let hotkeys = try UI.button(AppSettingsPane.hotkeys.title, in: host)
                    #expect(permissions.frame.minX > appearance.frame.maxX)
                    #expect(hotkeys.frame.minX > permissions.frame.maxX)
                    try permissions.press()
                    try await UI.wait { UI.contains(L("settings.permissionStatus.title"), in: host) }
                    try await waitForPermissionActions(in: host)
                    #expect(!UI.contains(L("settings.launchAtLogin.title"), in: host))
                    for permission in SettingsPermission.allCases {
                        #expect(UI.contains(permission.title, in: host))
                    }
                    try UI.snapshot(host, name: "permissions-navigation-\(Int(width))")
                    try UI.button(AppSettingsPane.general.title, in: host).press()
                    try await UI.wait { UI.contains(L("settings.launchAtLogin.title"), in: host) }
                    #expect(!UI.contains(L("settings.permissionStatus.title"), in: host))
                }
            }
        }
    }

    @Test func `permissions render in both languages and appearances without clipped actions`() async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-render-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            settings.interfaceStyle = .classic
            let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: .settings,
                                        modelLibrary: AskModelLibrary(
                                            defaults: settings.defaults,
                                            automaticallyLoadsCatalog: false
                                        ))
            for language in [AppLanguage.english, .simplifiedChinese] {
                model.setAppLanguage(language)
                for dark in [false, true] {
                    model.setAppearanceMode(dark ? .dark : .light)
                    for width: CGFloat in [720, 1100] {
                        try await UI.withWindow(StudioView(viewModel: model, settingsPane: .permissions),
                                                width: width, height: 1100) { window, host in
                            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            try await UI.wait {
                                UI.elements(in: host).contains {
                                    $0.value("accessibilityIdentifier") as? String == "settings.permissions.fullDiskAccess.action"
                                }
                            }
                            try await waitForPermissionActions(in: host)
                            let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                            for permission in SettingsPermission.allCases {
                                let button = try #require(UI.elements(in: host).first {
                                    $0.value("accessibilityIdentifier") as? String == "settings.permissions.\(permission.rawValue).action"
                                })
                                #expect(button.frame.width > 30 && button.frame.minX >= bounds.minX - 1)
                                #expect(button.frame.maxX <= bounds.maxX + 1)
                            }
                            try UI.snapshot(
                                host,
                                name: "permissions-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func `rendered permission buttons refresh and request only their own permission`() async throws {
        try await UI.withFixture { _ in
            let probe = PermissionSystemProbe()
            probe.coreGranted = true
            let model = PermissionsSettingsModel(service: probe.service)
            try await UI.withWindow(PermissionsSettingsView(model: model), width: 620, height: 1300) { _, host in
                try await UI.wait { model.statuses.count == SettingsPermission.allCases.count }
                @MainActor func action(_ permission: SettingsPermission) throws -> UI.Element {
                    try #require(UI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "settings.permissions.\(permission.rawValue).action"
                    })
                }
                try action(.camera).press()
                try await UI.wait { model.statuses[.camera] == .granted && model.requestingPermission == nil }
                #expect(probe.requests == ["camera"])
                try action(.microphone).press()
                try await UI.wait { probe.requests == ["camera", "microphone"] && model.requestingPermission == nil }
                probe.screen.granted = true
                let refresh = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "settings.permissions.refresh"
                })
                try refresh.press()
                try await UI.wait { model.statuses[.screenRecording] == .granted }
                probe.diskGranted = true
                NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                try await UI.wait { model.statuses[.fullDiskAccess] == .granted }
                probe.failRequest = true
                try action(.calendar).press()
                try await UI.wait { UI.contains(
                    L("settings.permissions.requestFailed", SettingsPermission.calendar.title),
                    in: host
                ) }
                try UI.snapshot(host, name: "permissions-error")
            }
        }
    }

    private func waitForPermissionActions(in host: NSView) async throws {
        try await UI.wait {
            UI.elements(in: host).contains {
                $0.value("accessibilityIdentifier") as? String == "settings.permissions.fullDiskAccess.action"
                    && $0.value("isAccessibilityEnabled") as? Bool == true
            }
        }
    }
}

@MainActor
private final class PermissionSystemProbe {
    var coreGranted = false
    let screen = PermissionScreenCaptureProbe()
    var camera: AVAuthorizationStatus = .notDetermined
    var calendar: CalendarAccess = .unknown
    var notifications: UNAuthorizationStatus? = .notDetermined
    var diskGranted = false
    var failRequest = false
    var requests: [String] = []
    var opened: [URL] = []

    var service: SettingsPermissionService {
        .system(SettingsPermissionSystem(
            coreGranted: { _ in self.coreGranted },
            requestCore: { self.requests.append($0.rawValue) },
            screenCapture: screen,
            cameraAuthorization: { self.camera },
            requestCamera: { self.requests.append("camera"); self.camera = .authorized },
            calendarAccess: { self.calendar },
            requestCalendar: {
                self.requests.append("calendar")
                if self.failRequest {
                    throw ProbeError()
                }
                self.calendar = .allowed
            },
            notificationAuthorization: { self.notifications },
            requestNotifications: {
                self.requests.append("notifications")
                if self.failRequest {
                    throw ProbeError()
                }
                self.notifications = .authorized
            },
            fullDiskAccessGranted: { self.diskGranted },
            openURL: { self.opened.append($0) }
        ))
    }

    private struct ProbeError: Error {}
}

private final class PermissionScreenCaptureProbe: ScreenCapturePermissionProviding {
    var granted = false
    var grantOnRequest = false
    var requests = 0
    var settingsOpened = 0
    var isGranted: Bool {
        granted
    }

    func request() -> Bool {
        requests += 1
        granted = grantOnRequest
        return granted
    }

    func requestOnce() {
        _ = request()
    }

    func openSystemSettings() {
        settingsOpened += 1
    }
}
