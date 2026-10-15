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
