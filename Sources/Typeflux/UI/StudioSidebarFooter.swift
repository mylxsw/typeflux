import SwiftUI

/// Settings uses the same account row as Chat; Cloud features live on the account page.
struct StudioSidebarFooter: View {
    @ObservedObject var auth = AuthState.shared
    let defaults: UserDefaults
    let compact: Bool
    let onAccountAction: () -> Void

    var body: some View {
        SidebarAccountFooter(auth: auth, compact: compact, defaults: defaults,
                             onSignIn: onAccountAction, onOpenAccount: onAccountAction)
    }
}
