import SwiftUI

/// All app appearance preferences share the existing store and live-update paths.
struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ModelSurface {
                VStack(alignment: .leading, spacing: 18) {
                    settingRow(title: L("settings.appearance.title")) {
                        StudioSegmentedPicker(
                            options: AppearanceMode.allCases.map { ($0.displayName, $0) },
                            selection: Binding(get: { viewModel.appearanceMode }, set: viewModel.setAppearanceMode),
                            size: .compact,
                            optionIdentifier: { "settings.appearance." + $0.rawValue }
                        )
                    }
                    Divider()
                    settingRow(title: L("settings.interfaceStyle.title")) {
                        StudioSegmentedPicker(
                            options: InterfaceStyle.allCases.map { ($0.displayName, $0) },
                            selection: Binding(get: { viewModel.interfaceStyle }, set: viewModel.setInterfaceStyle),
                            size: .compact,
                            optionIdentifier: { "settings.interfaceStyle." + $0.rawValue }
                        )
                    }
                    if viewModel.interfaceStyle.usesGlass {
                        Divider()
                        LiquidGlassIntensitySetting(value: Binding(
                            get: { viewModel.liquidGlassIntensity }, set: viewModel.setLiquidGlassIntensity
                        ))
                    }
                }
                .padding(18)
            }
            ModelSurface {
                LauncherWindowModeSetting(selection: Binding(
                    get: { viewModel.launcherWindowMode }, set: viewModel.setLauncherWindowMode
                ))
            }
            ModelSurface {
                settingRow(title: L("settings.language.title")) {
                    SettingsMenuPicker(
                        title: L("settings.language.title"),
                        options: AppLanguage.allCases.map { ($0.displayName, $0) },
                        selection: Binding(get: { viewModel.appLanguage }, set: viewModel.setAppLanguage)
                    )
                    .frame(width: 180)
                    .accessibilityIdentifier("settings.appearance.language")
                }
                .padding(18)
            }
        }
    }

    /// Stack the label above its control when translations or a narrow window need room.
    private func settingRow(title: String, @ViewBuilder control: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                settingLabel(title).fixedSize()
                Spacer(minLength: 0)
                control()
            }
            VStack(alignment: .leading, spacing: 10) {
                settingLabel(title)
                control()
            }
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
