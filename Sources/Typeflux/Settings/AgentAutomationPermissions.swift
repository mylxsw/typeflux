import AppKit
import CoreGraphics

/// The macOS permissions Ask's computer and browser tools rely on: Accessibility to click
/// and type, Screen Recording to see the screen. Closures keep the settings view testable.
struct AgentAutomationPermissions {
    var accessibilityGranted: () -> Bool
    var screenRecordingGranted: () -> Bool
    var requestAccessibility: @MainActor () -> Void
    var requestScreenRecording: @MainActor () -> Void

    static let live = AgentAutomationPermissions(
        accessibilityGranted: { PrivacyGuard.isAccessibilityGranted() },
        screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
        requestAccessibility: { Task { await PrivacyGuard.requestPermission(.accessibility) } },
        requestScreenRecording: {
            // The request lists Typeflux in System Settings, so the pane opened next shows it.
            if !AskContextCapture.requestScreenCaptureAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    )

    static func fixed(accessibility: Bool, screenRecording: Bool) -> AgentAutomationPermissions {
        AgentAutomationPermissions(accessibilityGranted: { accessibility }, screenRecordingGranted: { screenRecording },
                                   requestAccessibility: {}, requestScreenRecording: {})
    }
}
