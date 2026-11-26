import SwiftUI

struct SidebarAccountFooterLayout<Identity: View, Promotion: View, Controls: View>: View {
    let signedIn: Bool
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let promotion: () -> Promotion
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            promotion()
            Rectangle().fill(AccountTone.separator).frame(height: 0.5)
            HStack(spacing: 9) {
                identity().layoutPriority(1)
                Spacer(minLength: 4)
                controls()
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: signedIn ? 52 : 56)
        }
        .accessibilityIdentifier("sidebar.accountFooter")
    }
}
