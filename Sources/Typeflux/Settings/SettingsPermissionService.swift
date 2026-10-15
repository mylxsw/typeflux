import AppKit
import AVFoundation
import UserNotifications

/// System adapters are injectable so permission buttons can be tested without showing OS prompts.
@MainActor
struct SettingsPermissionSystem {
    var coreGranted: (PrivacyGuard.PermissionID) -> Bool
    var requestCore: (PrivacyGuard.PermissionID) async -> Void
    var screenCapture: any ScreenCapturePermissionProviding
    var cameraAuthorization: () -> AVAuthorizationStatus
    var requestCamera: () async -> Void
    var calendarAccess: () async -> CalendarAccess
    var requestCalendar: () async throws -> Void
    var notificationAuthorization: () async -> UNAuthorizationStatus?
    var requestNotifications: () async throws -> Void
    var fullDiskAccessGranted: () -> Bool
    var openURL: (URL) -> Void

    static var live: Self {
        let calendar = EventKitEventProvider()
        return Self(
            coreGranted: { PrivacyGuard.snapshot(for: $0).isGranted },
            requestCore: { await PrivacyGuard.requestPermission($0) },
            screenCapture: ScreenCapturePermission.live,
            cameraAuthorization: { AVCaptureDevice.authorizationStatus(for: .video) },
            requestCamera: { _ = await AVCaptureDevice.requestAccess(for: .video) },
            calendarAccess: { await calendar.access() },
            requestCalendar: { _ = try await calendar.requestAccess() },
            notificationAuthorization: {
                // UNUserNotificationCenter requires an app bundle; SwiftPM test executables have none.
                guard PrivacyGuard.isRunningInAppBundle else { return nil }
                return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestNotifications: {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            },
            fullDiskAccessGranted: { AskFullDiskAccess.isGranted() },
            openURL: { _ = NSWorkspace.shared.open($0) }
        )
    }
}

@MainActor
struct SettingsPermissionService {
    var status: (SettingsPermission) async -> SettingsPermissionStatus
    var request: (SettingsPermission) async throws -> Void

    static func system(_ adapters: SettingsPermissionSystem? = nil) -> Self {
        let system = adapters ?? .live
        return Self(status: { await readStatus($0, system: system) }, request: {
            try await requestPermission($0, system: system)
        })
    }

    private static func readStatus(_ permission: SettingsPermission, system: SettingsPermissionSystem) async
        -> SettingsPermissionStatus {
        if let core = permission.corePermission {
            return system.coreGranted(core) ? .granted : .notGranted
        }
        switch permission {
        case .screenRecording: return system.screenCapture.isGranted ? .granted : .notGranted
        case .camera: return system.cameraAuthorization() == .authorized ? .granted : .notGranted
        case .calendar: return await system.calendarAccess() == .allowed ? .granted : .notGranted
        case .notifications:
            guard let status = await system.notificationAuthorization() else { return .systemManaged }
            return [.authorized, .provisional].contains(status) ? .granted : .notGranted
        case .fullDiskAccess: return system.fullDiskAccessGranted() ? .granted : .notGranted
        case .automation: return .systemManaged
        case .microphone, .speechRecognition, .accessibility: preconditionFailure("Core permissions handled above")
        }
    }

    private static func requestPermission(
        _ permission: SettingsPermission,
        system: SettingsPermissionSystem
    ) async throws {
        if let core = permission.corePermission {
            await system.requestCore(core)
            return
        }
        switch permission {
        case .screenRecording:
            if system.screenCapture.isGranted {
                system.screenCapture.openSystemSettings()
            } else {
                system.screenCapture.requestOrOpenSettings()
            }
        case .camera where system.cameraAuthorization() == .notDetermined:
            await system.requestCamera()
        case .calendar where await system.calendarAccess() == .unknown:
            try await system.requestCalendar()
        case .notifications where await system.notificationAuthorization() == .notDetermined:
            try await system.requestNotifications()
        default:
            system.openURL(permission.settingsURL)
        }
    }
}
