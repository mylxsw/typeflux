import SwiftUI

/// Where links in Chat messages open: the side panel's web tabs or the system browser.
/// ⌘-click always uses the system browser.
struct AskLinkSettingsView: View {
    let settings: SettingsStore
    @State private var opening = AskLinkOpening.sidePanel

    var body: some View {
        TFFormRow(title: L("ask.settings.links.title"), detail: L("ask.settings.links.subtitle"), icon: "link") {
            TFPopUpButton(title: L("ask.settings.links.title"),
                          options: AskLinkOpening.allCases.map { TFOption($0, Self.title($0)) },
                          selection: $opening,
                          width: TFMetrics.formControlWidth, identifier: "agent.settings.linkOpening")
        }
        .onAppear { opening = settings.askLinkOpening }
        .onChange(of: opening) { settings.askLinkOpening = $0 }
    }

    static func title(_ opening: AskLinkOpening) -> String {
        switch opening {
        case .sidePanel: L("ask.settings.links.sidePanel")
        case .browser: L("ask.settings.links.browser")
        }
    }
}
