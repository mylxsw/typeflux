import SwiftUI

struct StudioSidebar: View {
    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void
    let onAccountAction: () -> Void
    let defaults: UserDefaults
    var count: (StudioSection) -> Int? = { _ in nil }
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        GeometryReader { proxy in
            List(StudioSection.sidebarUpperCases, selection: Binding<StudioSection?>(
                get: {
                    let section = currentSection.sidebarSection
                    return StudioSection.sidebarUpperCases.contains(section) ? section : nil
                },
                set: {
                    if let section = $0 {
                        onSelect(section)
                    }
                }
            )) { section in
                TypefluxButton(kind: .borderless, action: { onSelect(section) }, label: {
                    HStack {
                        Label {
                            Text(section.sidebarTitle)
                        } icon: {
                            Image(systemName: section.sidebarIconName).foregroundStyle(TypefluxColor.accent.color)
                        }
                        Spacer(minLength: 0)
                        if let count = count(section) {
                            Text(count, format: .number).font(.subheadline).monospacedDigit()
                                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                        }
                    }
                })
                .accessibilityLabel(section.sidebarTitle)
                .tag(section)
                .accessibilityIdentifier("studio.sidebar.\(section.rawValue)")
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StudioSidebarFooter(defaults: defaults, compact: proxy.size.height < 400,
                                    onAccountAction: onAccountAction)
            }
        }
        .environment(\.locale, localization.locale)
    }
}
