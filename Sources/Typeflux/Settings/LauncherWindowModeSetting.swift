import SwiftUI

struct LauncherWindowModeSetting: View {
    @Binding var selection: AskLauncherWindowMode

    var body: some View {
        TypefluxSettingsRow(L("ask.settings.windowMode.title"), description: L("ask.settings.windowMode.detail")) {
            TypefluxSegmentedControl(L("ask.settings.windowMode.title"), selection: $selection) {
                ForEach(AskLauncherWindowMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                        .accessibilityIdentifier("launcher.settings.windowMode." + mode.rawValue)
                }
            }
        }
    }
}
