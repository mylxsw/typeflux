import AppKit
import ApplicationServices

/// Reuses Settings permission actions while keeping guidance inside the onboarding window.
@MainActor
struct OnboardingPermissionsSystem {
    let service: SettingsPermissionService
    let opensSettings: (SettingsPermission) async -> Bool

    init(adapters: SettingsPermissionSystem? = nil,
         showsDialog: ((PrivacyGuard.PermissionID) -> Bool)? = nil,
         requestDialog: @escaping (PrivacyGuard.PermissionID) async
             -> Void = { await PrivacyGuard.requestPermission($0) },
         promptAccessibility: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         },
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        let showsDialog = showsDialog ?? { PrivacyGuard.willShowInAppDialog(for: $0) }
        var system = adapters ?? SettingsPermissionSystem.live
        system.openURL = openURL
        if adapters == nil {
            system.screenCapture = ScreenCapturePermission(openURL: { url in
                Task { @MainActor in openURL(url) }
            })
        }
        system.requestCore = { core in
            if showsDialog(core) {
                await requestDialog(core)
            } else {
                if core == .accessibility {
                    promptAccessibility()
                }
                if let permission = SettingsPermission(rawValue: core.rawValue) {
                    openURL(permission.settingsURL)
                }
            }
        }
        let adapters = system
        service = .system(adapters)
        opensSettings = { permission in
            if let core = permission.corePermission {
                return !showsDialog(core)
            }
            switch permission {
            case .camera: return adapters.cameraAuthorization() != .notDetermined
            case .calendar: return await adapters.calendarAccess() != .unknown
            case .notifications: return await adapters.notificationAuthorization() != .notDetermined
            default: return true
            }
        }
    }
}
