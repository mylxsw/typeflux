import AppKit

/// The macOS permissions Ask's computer and browser tools rely on: Accessibility to click
/// and type, Screen Recording to see the screen. Closures keep the settings view testable.
struct AgentAutomationPermissions {
    var accessibilityGranted: () -> Bool
    var screenRecordingGranted: () -> Bool
    var requestAccessibility: @MainActor () -> Void
    var requestScreenRecording: @MainActor () -> Void

    static let live = system(screenCapture: ScreenCapturePermission.live)

    static func system(screenCapture: any ScreenCapturePermissionProviding) -> AgentAutomationPermissions {
        AgentAutomationPermissions(
            accessibilityGranted: { PrivacyGuard.isAccessibilityGranted() },
            screenRecordingGranted: { screenCapture.isGranted },
            requestAccessibility: { Task { await PrivacyGuard.requestPermission(.accessibility) } },
            // The request lists Typeflux in System Settings, so the pane opened next shows it.
            requestScreenRecording: { screenCapture.requestOrOpenSettings() }
        )
    }

    static func fixed(accessibility: Bool, screenRecording: Bool) -> AgentAutomationPermissions {
        AgentAutomationPermissions(accessibilityGranted: { accessibility }, screenRecordingGranted: { screenRecording },
                                   requestAccessibility: {}, requestScreenRecording: {})
    }
}
