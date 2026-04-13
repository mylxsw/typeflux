import AppKit

protocol ActivationPolicyControlling: AnyObject {
    var currentActivationPolicy: NSApplication.ActivationPolicy { get }
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy)
}

extension NSApplication: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy {
        activationPolicy()
    }

    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        _ = setActivationPolicy(policy)
    }
}

final class DockVisibilityController {
    static let shared = DockVisibilityController(app: NSApplication.shared)

    private let app: ActivationPolicyControlling
    private var presentedWindowIDs = Set<ObjectIdentifier>()

    init(app: ActivationPolicyControlling) {
        self.app = app
    }

    func windowDidShow(_ window: NSWindow) {
        setPresented(true, for: window)
    }

    func windowDidHide(_ window: NSWindow) {
        setPresented(false, for: window)
    }

    func setPresented(_ isPresented: Bool, for token: AnyObject) {
        let identifier = ObjectIdentifier(token)

        if isPresented {
            let inserted = presentedWindowIDs.insert(identifier).inserted
            guard inserted else { return }
        } else {
            let removed = presentedWindowIDs.remove(identifier) != nil
            guard removed else { return }
        }

        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let targetPolicy: NSApplication.ActivationPolicy = presentedWindowIDs.isEmpty ? .accessory : .regular
        guard app.currentActivationPolicy != targetPolicy else { return }
        app.applyActivationPolicy(targetPolicy)
    }
}
