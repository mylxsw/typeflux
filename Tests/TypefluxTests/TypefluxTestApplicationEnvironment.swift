import AppKit
@testable import Typeflux

/// AppKit's activation and accessibility configuration belongs to the test process, not a window fixture.
@MainActor
enum TypefluxTestApplicationEnvironment {
    static let enhancedUIAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    private static var configured = false
    // The UI runner remains present between window fixtures. Shared production controllers must not
    // interpret closing their last tracked window as permission to hide this process.
    private static let hostPresentation = NSObject()

    static func prepare() {
        // Switching back to accessory mode between tests can hide and terminate the Swift Testing host.
        // Leave the runner's delegate intact, and keep this configuration until the process exits.
        let application = NSApplication.shared
        if !configured {
            application.setActivationPolicy(.regular)
            DockVisibilityController.shared.setPresented(true, for: hostPresentation)
            configured = true
        }
        // Legacy UI fixtures can still disable AX on teardown. Re-enable it at the next fixture boundary,
        // without disabling it here or switching activation policy again.
        if application.accessibilityAttributeValue(enhancedUIAttribute) as? Bool != true {
            application.accessibilitySetValue(true, forAttribute: enhancedUIAttribute)
        }
    }
}
