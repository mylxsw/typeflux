import SwiftUI

struct LauncherWindowModeSetting: View {
    @Binding var selection: AskLauncherWindowMode
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(L("ask.settings.windowMode.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColors.textPrimary)
                    .accessibilityHint(L("ask.settings.windowMode.detail"))
                SettingsDescriptionHint(detail: L("ask.settings.windowMode.detail"), visible: isHovering)
            }
            HStack(spacing: 12) {
                ForEach(AskLauncherWindowMode.allCases, id: \.self) { mode in
                    TFChoiceCard(title: mode.title, isSelected: selection == mode) { selection = mode } preview: {
                        preview(mode)
                    }
                    .accessibilityValue(selection == mode ? L("ask.settings.windowMode.selected") : "")
                    .accessibilityIdentifier("launcher.settings.windowMode." + mode.rawValue)
                }
            }
        }
        .padding(14)
        .onHover { isHovering = $0 }
    }

    /// A small schematic of Typeflux's header, results and bottom controls.
    private func preview(_ mode: AskLauncherWindowMode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                Capsule().fill(StudioTheme.textTertiary.opacity(0.35)).frame(width: 38, height: 4)
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(10)
            if mode == .complete {
                Rectangle().fill(StudioTheme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0 ..< 3) { index in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(AskTheme.accent.opacity(index == 0 ? 0.65 : 0.25))
                                .frame(width: 10, height: 10)
                            Capsule().fill(StudioTheme.textTertiary.opacity(0.3)).frame(
                                width: index == 1 ? 42 : 55,
                                height: 4
                            )
                            Spacer(minLength: 0)
                        }
                    }
                }.padding(10)
                Rectangle().fill(StudioTheme.border).frame(height: 1)
                HStack {
                    Capsule().fill(StudioTheme.textTertiary.opacity(0.3)).frame(width: 26, height: 4)
                    Spacer()
                    Circle().fill(AskTheme.accent.opacity(0.6)).frame(width: 9, height: 9)
                }.padding(8)
            }
        }
        .background(StudioTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.border) }
        .frame(maxWidth: 160)
        .frame(height: 124, alignment: .top)
        .accessibilityHidden(true)
    }
}
