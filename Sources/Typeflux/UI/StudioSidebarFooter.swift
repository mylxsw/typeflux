import SwiftUI

/// A single account row; Cloud features are described on the account page.
struct StudioSidebarFooter: View {
    @ObservedObject var auth = AuthState.shared
    let compact: Bool
    let onAccountAction: () -> Void
    private let defaults: UserDefaults

    init(defaults: UserDefaults, compact: Bool, onAccountAction: @escaping () -> Void) {
        self.defaults = defaults
        self.compact = compact
        self.onAccountAction = onAccountAction
    }

    var body: some View {
        SidebarAccountFooter(auth: auth, compact: compact, defaults: defaults,
                             onSignIn: onAccountAction, onOpenAccount: onAccountAction)
    }
}
