import SwiftUI

/// All app appearance preferences share the existing store and live-update paths.
struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection {
                TFFormRow(title: L("settings.appearance.title")) {
                    TFSegmentedControl(
                        options: AppearanceMode.allCases.map { TFOption($0, $0.displayName) },
                        selection: Binding(get: { viewModel.appearanceMode }, set: viewModel.setAppearanceMode),
                        identifier: { "settings.appearance." + $0.rawValue }
                    )
                }
                TFDivider.form
                TFFormRow(title: L("settings.interfaceStyle.title")) {
                    TFSegmentedControl(
                        options: InterfaceStyle.allCases.map { TFOption($0, $0.displayName) },
                        selection: Binding(get: { viewModel.interfaceStyle }, set: viewModel.setInterfaceStyle),
                        identifier: { "settings.interfaceStyle." + $0.rawValue }
                    )
                }
                if viewModel.interfaceStyle.usesGlass {
                    TFDivider.form
                    LiquidGlassIntensitySetting(value: Binding(
                        get: { viewModel.liquidGlassIntensity }, set: viewModel.setLiquidGlassIntensity
                    ))
                    .padding(14)
                }
            }
            TFFormSection(footnote: L("settings.appIcon.note")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("settings.appIcon.title"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TFColors.textPrimary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                        ForEach(AppIconStyle.allCases) { style in
                            TFChoiceCard(
                                title: style.displayName,
                                isSelected: viewModel.appIconStyle == style,
                                action: { viewModel.setAppIconStyle(style) }
                            ) {
                                if let image = AppIconController.image(for: style) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 72, height: 72)
                                }
                            }
                            .accessibilityIdentifier("settings.appIcon." + style.rawValue)
                        }
                    }
                }
                .padding(14)
            }
            TFFormSection {
                LauncherWindowModeSetting(selection: Binding(
                    get: { viewModel.launcherWindowMode }, set: viewModel.setLauncherWindowMode
                ))
            }
            TFFormSection {
                TFFormRow(title: L("settings.language.title")) {
                    TFPopUpButton(
                        title: L("settings.language.title"),
                        options: AppLanguage.allCases.map { TFOption($0, $0.displayName) },
                        selection: Binding(get: { viewModel.appLanguage }, set: viewModel.setAppLanguage),
                        width: TFMetrics.formControlWidth,
                        identifier: "settings.appearance.language"
                    )
                }
            }
        }
    }
}
