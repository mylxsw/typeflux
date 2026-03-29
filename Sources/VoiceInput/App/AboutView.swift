import AppKit
import SwiftUI

struct AboutView: View {
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared

    private let websiteURL = URL(string: "https://github.com/mylxsw")!
    private let projectURL = URL(string: "https://github.com/mylxsw/voice-input")!

    var body: some View {
        ZStack {
            StudioTheme.windowBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
                    headerCard
                    detailsCard
                }
                .padding(StudioTheme.Insets.cardDefault)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
    }

    private var headerCard: some View {
        StudioCard {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.92, green: 0.96, blue: 1.00),
                                    Color(red: 0.84, green: 0.91, blue: 1.00)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)

                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    Text(L("about.appName"))
                        .font(.studioDisplay(StudioTheme.Typography.heroTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    Text(L("about.subtitle"))
                        .font(.studioBody(StudioTheme.Typography.bodyLarge))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

                Spacer()
            }
        }
    }

    private var detailsCard: some View {
        StudioCard {
            StudioSectionTitle(title: L("about.details"))

            detailRow(
                icon: "person.crop.circle",
                title: L("about.developer"),
                value: "@mylxsw",
                subtitle: L("about.developer.subtitle")
            )

            divider

            detailLinkRow(
                icon: "globe",
                title: L("about.website"),
                value: "github.com/mylxsw",
                subtitle: websiteURL.absoluteString,
                url: websiteURL
            )

            divider

            detailLinkRow(
                icon: "shippingbox",
                title: L("about.project"),
                value: "Typeflux",
                subtitle: L("about.project.subtitle"),
                url: projectURL
            )

            divider

            detailRow(
                icon: "number",
                title: L("about.build"),
                value: versionDescription,
                subtitle: L("about.build.subtitle")
            )
        }
    }

    private func detailRow(icon: String, title: String, value: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
            detailIcon(icon)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(value)
                    .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            Spacer()
        }
    }

    private func detailLinkRow(icon: String, title: String, value: String, subtitle: String, url: URL) -> some View {
        Button {
            open(url)
        } label: {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                detailIcon(icon)

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Text(value)
                        .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(subtitle)
                        .font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func detailIcon(_ icon: String) -> some View {
        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
            .fill(StudioTheme.accentSoft)
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.Typography.iconRegular, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)
            )
    }

    private var divider: some View {
        Rectangle()
            .fill(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
            .frame(height: 1)
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
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
