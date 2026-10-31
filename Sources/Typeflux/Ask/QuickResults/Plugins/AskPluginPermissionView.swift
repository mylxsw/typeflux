import AppKit
import SwiftUI

/// An actionable setup state, separate from errors and their icon-only recovery controls.
struct AskPluginPermissionView: View {
    var permission: AskPluginPermission
    var message: String
    var actions: [AskPluginAction]
    var onAction: (AskPluginAction) -> Void

    private var primary: AskPluginAction? { actions.first { $0.shortcut == .enter } }
    private var secondary: AskPluginAction? { actions.first { $0.shortcut == .commandR } }

    static func height(permission: AskPluginPermission, message: String) -> CGFloat {
        let width = AskMetrics.launcherWidth - AskMetrics.launcherGutter * 2
            - AskPluginResultsView.listPadding * 2 - 48
        let title = AskPluginResultsView.textHeight(permission.title, font: .systemFont(ofSize: 18, weight: .semibold), width: width - 58)
        return 48 + max(44, 17 + title) + 14
            + AskPluginResultsView.textHeight(message, font: .systemFont(ofSize: 13.5), lineSpacing: 3, width: width)
            + 20 + 36 + 14
            + max(16, AskPluginResultsView.textHeight(permission.detail, font: .systemFont(ofSize: 11.5), lineSpacing: 2, width: width - 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let icon = AskLauncherFeatureIcons.image(for: permission.icon, style: .light) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("apple.search.permissionEyebrow"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.textSecondary)
                    Text(permission.title).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text(message).font(.system(size: 13.5)).lineSpacing(3)
                .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack(spacing: 16) {
                if let primary {
                    Button { onAction(primary) } label: {
                        HStack(spacing: 16) {
                            Text(primary.title).font(.system(size: 13, weight: .semibold))
                            Image(systemName: "return").font(.system(size: 11, weight: .medium)).opacity(0.7)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(AskTheme.accent).controlSize(.large)
                    .frame(height: 36).accessibilityLabel(primary.title)
                    .accessibilityIdentifier("ask.plugin.permission.primary")
                }
                if let secondary {
                    Button(secondary.title) { onAction(secondary) }
                        .buttonStyle(.plain).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .accessibilityIdentifier("ask.plugin.permission.recheck")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.shield").font(.system(size: 11)).frame(width: 14, height: 14).padding(.top, 2)
                    .accessibilityHidden(true)
                Text(permission.detail).font(.system(size: 11.5)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.plugin.permission.detail")
            }
            .foregroundStyle(StudioTheme.textSecondary).padding(.top, 14)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.permission.card")
    }
}
