import AppKit

/// AppKit's activation and accessibility configuration belongs to the test process, not a window fixture.
@MainActor
enum TypefluxTestApplicationEnvironment {
    static let enhancedUIAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    private static var configured = false

    static func prepare() {
        // Switching back to accessory mode between tests can hide and terminate the Swift Testing host.
        // Leave the runner's delegate intact, and keep this configuration until the process exits.
        guard !configured else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.accessibilitySetValue(true, forAttribute: enhancedUIAttribute)
        configured = true
    }
}
