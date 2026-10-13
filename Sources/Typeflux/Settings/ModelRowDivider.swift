import SwiftUI

struct ModelRowDivider: View {
    var leading: CGFloat = 18

    var body: some View {
        Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
            .padding(.leading, leading).padding(.trailing, 18)
    }
}
