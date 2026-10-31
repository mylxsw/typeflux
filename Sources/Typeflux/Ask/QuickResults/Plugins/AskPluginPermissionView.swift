import AppKit
import SwiftUI

/// A focused permission state with the next action beside its purpose.
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
        return 80 + 16
            + AskPluginResultsView.textHeight(permission.title, font: .systemFont(ofSize: 26, weight: .semibold), width: width)
            + 10 + AskPluginResultsView.textHeight(message, font: .systemFont(ofSize: 15.5), lineSpacing: 3, width: width)
            + 28 + 36 + 36
    }

    var body: some View {
        VStack(spacing: 0) {
            if let icon = AskLauncherFeatureIcons.image(for: permission.icon, style: .light) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 80, height: 80).accessibilityHidden(true)
            }
            Text(permission.title).font(.system(size: 26, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            Text(message).font(.system(size: 15.5)).lineSpacing(3)
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            HStack(spacing: 16) {
                if let primary {
                    Button { onAction(primary) } label: {
                        Text(primary.title).font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 124, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent).tint(AskTheme.accent).controlSize(.large)
                    .accessibilityLabel(primary.title)
                    .accessibilityIdentifier("ask.plugin.permission.primary")
                }
                if let secondary {
                    Button(secondary.title) { onAction(secondary) }
                        .buttonStyle(.plain).font(.system(size: 13))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .accessibilityIdentifier("ask.plugin.permission.recheck")
                }
            }
            .padding(.top, 28)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24).padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.permission.card")
    }
}
