import SwiftUI

/// Shared metrics for single-line settings fields, menus and actions.
enum SettingsControlMetrics {
    static let height: CGFloat = 30
    static let fontSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 10
}

struct SettingsControlChrome: ViewModifier {
    var focused = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background(ModelVisualStyle.control,
                        in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                .strokeBorder(focused ? ModelVisualStyle.accent : ModelVisualStyle.border, lineWidth: focused ? 2 : 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A field-sized menu that preserves native keyboard navigation and selection marks.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.value)
                    }
                }
            } label: {
                Text(options.first { $0.value == selection }?.label ?? title)
                    .lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 18)
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .allowsHitTesting(false)
        }
        .font(.system(size: SettingsControlMetrics.fontSize))
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(.horizontal, SettingsControlMetrics.horizontalPadding)
        .frame(height: SettingsControlMetrics.height)
        .modifier(SettingsControlChrome())
    }
}

/// Search shared by the Models and Agent pages, including a named clear action.
struct SettingsSearchBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 240
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
                .font(.system(size: SettingsControlMetrics.fontSize)).focused($focused)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain).accessibilityLabel(L("common.clear"))
            }
        }
        .padding(.horizontal, SettingsControlMetrics.horizontalPadding)
        .frame(width: width, height: SettingsControlMetrics.height)
        .modifier(SettingsControlChrome(focused: focused))
        .onAppear {
            // macOS may focus the first field before the pane finishes appearing.
            DispatchQueue.main.async { focused = false }
        }
    }
}
