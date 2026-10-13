import SwiftUI

struct ModelSectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.body)
            if let detail {
                Text(detail).font(.body)
            }
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 4)
    }
}
