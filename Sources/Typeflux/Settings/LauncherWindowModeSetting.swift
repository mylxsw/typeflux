import SwiftUI

struct LauncherWindowModeSetting: View {
    @Binding var selection: AskLauncherWindowMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.settings.windowMode.title"))
                .font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            HStack(spacing: 12) {
                ForEach(AskLauncherWindowMode.allCases, id: \.self) { mode in
                    option(mode)
                }
            }
            Text(L("ask.settings.windowMode.detail"))
                .font(.system(size: StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private func option(_ mode: AskLauncherWindowMode) -> some View {
        let selected = selection == mode
        return Button { selection = mode } label: {
            VStack(spacing: 10) {
                preview(mode)
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AskTheme.accent : StudioTheme.textTertiary)
                    Text(mode.title).foregroundStyle(StudioTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13, weight: .medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(selected ? AskTheme.accent.opacity(0.08) : StudioTheme.cardSurface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? AskTheme.accent : StudioTheme.border, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? L("ask.settings.windowMode.selected") : "")
        .accessibilityAction { selection = mode }
        .accessibilityIdentifier("launcher.settings.windowMode." + mode.rawValue)
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
