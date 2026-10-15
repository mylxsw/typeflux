import Foundation

/// The settings catalog includes feature permissions without making them onboarding requirements.
enum SettingsPermission: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility
    case screenRecording
    case camera
    case calendar
    case notifications
    case automation
    case fullDiskAccess

    var id: String {
        rawValue
    }

    var corePermission: PrivacyGuard.PermissionID? {
        PrivacyGuard.PermissionID(rawValue: rawValue)
    }

    var isRequired: Bool {
        corePermission != nil
    }

    var title: String {
        corePermission?.title ?? L("permission.\(rawValue).title")
    }

    var summary: String {
        corePermission?.summary ?? L("permission.\(rawValue).summary")
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .calendar: pane = "Privacy_Calendars"
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        case .automation: pane = "Privacy_Automation"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum SettingsPermissionStatus: Equatable {
    case granted
    case notGranted
    /// Automation grants belong to individual target apps, not one app-wide switch.
    case systemManaged

    var badgeText: String {
        switch self {
        case .granted: L("permission.badge.granted")
        case .notGranted: L("permission.badge.notGranted")
        case .systemManaged: L("permission.badge.systemManaged")
        }
    }

    var actionTitle: String {
        self == .notGranted ? L("permission.action.grantAccess") : L("permission.action.openSettings")
    }
}
