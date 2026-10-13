import SwiftUI

/// A small caption above a group of rows, with an optional hint after it.
struct AskWordBookSectionTitle: View {
    var text: String
    var hint: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(text).fontWeight(.semibold)
            if let hint { Text("· " + hint) }
        }
        .font(.caption)
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .padding(.top, 16).padding(.bottom, 8)
    }
}
