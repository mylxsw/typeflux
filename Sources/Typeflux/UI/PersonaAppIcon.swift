import AppKit
import SwiftUI

struct PersonaAppIcon: View {
    let identifier: String
    var url: URL?

    var body: some View {
        Group {
            if let appURL = url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable()
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
            }
        }.scaledToFit().frame(width: TypefluxControlHeight.navigationIcon.value(for: .classic),
                              height: TypefluxControlHeight.navigationIcon.value(for: .classic))
            .accessibilityHidden(true)
    }
}
