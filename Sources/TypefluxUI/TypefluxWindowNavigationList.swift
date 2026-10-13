import SwiftUI

struct TypefluxWindowNavigationList: View {
    @Environment(\.interfaceStyle) private var style
    let items: [TypefluxNavigationItem]
    @Binding var selection: String?

    var body: some View {
        List(items, selection: $selection) { item in
            HStack {
                Image(systemName: item.systemImage).foregroundStyle(TypefluxColor.accent.color)
                Text(item.title)
                Spacer()
                if let count = item.count {
                    Text(count, format: .number).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: TypefluxControlHeight.sidebarRow.value(for: style))
            .accessibilityElement(children: .combine)
            .tag(item.id)
        }
        .listStyle(.sidebar)
    }
}
