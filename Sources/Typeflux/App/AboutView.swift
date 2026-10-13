import AppKit
import SwiftUI

struct AboutView: View {
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared

    private let developerURL = URL(string: "https://gulu.ai")!
    private let websiteURL = URL(string: "https://typeflux.app")!
    private let privacyURL = URL(string: "https://typeflux.app/privacy")!
    private let projectURL = URL(string: "https://github.com/mylxsw/typeflux")!

    var body: some View {
        TypefluxForm {
            Section {
                HStack(spacing: 16) {
                    if let appIconImage {
                        Image(nsImage: appIconImage).resizable().frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("about.appName")).font(.headline)
                        Text(L("about.subtitle")).font(.body).foregroundStyle(.secondary)
                    }
                }
            }
            TypefluxFormSection(L("about.details")) {
                detailLinkRow(
                    icon: "person.crop.circle",
                    title: L("about.developer"),
                    value: "@mylxsw",
                    url: developerURL
                )
                detailLinkRow(icon: "globe", title: L("about.website"), value: "typeflux.app", url: websiteURL)
                detailLinkRow(
                    icon: "hand.raised",
                    title: L("about.privacy"),
                    value: L("about.privacy.value"),
                    url: privacyURL
                )
                detailLinkRow(icon: "shippingbox", title: L("about.project"), value: "Typeflux", url: projectURL)
                TypefluxSettingsRow(L("about.build"), description: L("about.build.subtitle")) {
                    Text(versionDescription).textSelection(.enabled)
                }
            }
        }
        .toolbar {
            ToolbarItem(id: "typeflux.window.title", placement: .principal) {
                Text(L("window.about")).font(.headline).accessibilityAddTraits(.isHeader)
            }
        }
        .typefluxWindowChrome(title: L("window.about"))
        .background(TypefluxColor.contentBackground.color)
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
    }

    private func detailLinkRow(icon: String, title: String, value: String, url: URL) -> some View {
        TypefluxNavigationRow(title, systemImage: icon, color: TypefluxColor.accent.color, detail: value) {
            open(url)
        }.help(url.absoluteString)
            .accessibilityIdentifier("about.link.\(icon)")
    }

    private var versionDescription: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let buildVersion, buildVersion != shortVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        return shortVersion
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var appIconImage: NSImage? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard icon.isValid else {
            return nil
        }

        icon.size = NSSize(width: 256, height: 256)
        return icon
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
