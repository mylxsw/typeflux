import SwiftUI

/// All app appearance preferences share the existing store and live-update paths.
struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        TypefluxForm {
            TypefluxFormSection(AppSettingsPane.appearance.title) {
                TypefluxSettingsRow(L("settings.appearance.title")) {
                    TypefluxSegmentedControl(L("settings.appearance.title"), selection: Binding(
                        get: { viewModel.appearanceMode }, set: viewModel.setAppearanceMode
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                                .accessibilityIdentifier("settings.appearance." + mode.rawValue)
                        }
                    }
                }
                TypefluxSettingsRow(L("settings.interfaceStyle.title")) {
                    TypefluxSegmentedControl(L("settings.interfaceStyle.title"), selection: Binding(
                        get: { viewModel.interfaceStyle }, set: viewModel.setInterfaceStyle
                    )) {
                        ForEach(InterfaceStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                                .accessibilityIdentifier("settings.interfaceStyle." + style.rawValue)
                        }
                    }
                }
                if viewModel.interfaceStyle.usesGlass {
                    LiquidGlassIntensitySetting(value: Binding(
                        get: { viewModel.liquidGlassIntensity }, set: viewModel.setLiquidGlassIntensity
                    ))
                }
            }
            TypefluxFormSection(L("ask.settings.windowMode.title")) {
                LauncherWindowModeSetting(selection: Binding(
                    get: { viewModel.launcherWindowMode }, set: viewModel.setLauncherWindowMode
                ))
            }
            TypefluxFormSection(L("settings.language.title")) {
                TypefluxSettingsRow(L("settings.language.title")) {
                    TypefluxPopup(L("settings.language.title"), selection: Binding(
                        get: { viewModel.appLanguage }, set: viewModel.setAppLanguage
                    ), borderless: true) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .accessibilityIdentifier("settings.appearance.language")
                }
            }
        }
        .id(localization.language)
    }
}
