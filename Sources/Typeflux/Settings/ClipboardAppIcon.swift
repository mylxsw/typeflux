import AppKit
import SwiftUI

/// The icon of an installed app, or a generic one.
struct ClipboardAppIcon: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let icon = ClipboardAppIconProvider.shared.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.body)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .frame(width: TypefluxControlHeight.navigationIcon.value(for: .classic),
               height: TypefluxControlHeight.navigationIcon.value(for: .classic))
    }
}
