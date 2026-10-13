import AppKit
@testable import Typeflux

/// Records Dock visibility policy without hiding the AppKit test host when its last settings window closes.
final class TypefluxTestActivationPolicyController: ActivationPolicyControlling {
    private(set) var currentActivationPolicy: NSApplication.ActivationPolicy = .regular

    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
    }
}
