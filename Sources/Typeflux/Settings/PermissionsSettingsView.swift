import AppKit
import SwiftUI

@MainActor
struct PermissionsSettingsView: View {
    @StateObject private var model: PermissionsSettingsModel

    init(model: PermissionsSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? PermissionsSettingsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection {
                TFFormRow(title: L("settings.permissionStatus.title"),
                          detail: L("settings.permissionStatus.subtitle")) {
                    TFButton(title: model.isRefreshing ? L("common.refreshing") : L("common.refresh"),
                             systemImage: "arrow.clockwise", isLoading: model.isRefreshing) {
                        Task { await model.refresh() }
                    }
                    .disabled(model.requestingPermission != nil)
                    .accessibilityIdentifier("settings.permissions.refresh")
                }
            }
            permissionSection(required: true)
            permissionSection(required: false)
            if let permission = model.requestError {
                TFFootnote(text: L("settings.permissions.requestFailed", permission.title))
                    .foregroundStyle(TFColors.warning)
                    .accessibilityIdentifier("settings.permissions.error")
            }
        }
        .accessibilityIdentifier("settings.permissions.page")
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func permissionSection(required: Bool) -> some View {
        let permissions = SettingsPermission.allCases.filter { $0.isRequired == required }
        return TFFormSection(title: L(required ? "settings.permissions.required" : "settings.permissions.optional"),
                             footnote: L(required ? "settings.permissions.requiredHint" :
                                 "settings.permissions.optionalHint")) {
            ForEach(Array(permissions.enumerated()), id: \.element.id) { index, permission in
                if index > 0 {
                    TFDivider.form
                }
                permissionRow(permission)
            }
        }
    }

    private func permissionRow(_ permission: SettingsPermission) -> some View {
        let status = model.statuses[permission]
        let tint = status == .granted ? TFColors.success : status == .notGranted ? TFColors.warning : TFColors
            .textSecondary
        return TFFormRow(title: permission.title, detail: permission.summary,
                         badge: status?.badgeText ?? L("common.refreshing"), badgeTint: tint,
                         systemImage: status == .granted ? "checkmark.circle.fill" : "lock.shield", imageTint: tint) {
            TFButton(title: status?.actionTitle ?? L("permission.action.openSettings"),
                     systemImage: status == .notGranted ? "lock.open.display" : "arrow.up.right.square",
                     kind: status == .notGranted ? .primary : .secondary,
                     isLoading: model.requestingPermission == permission) {
                Task { await model.request(permission) }
            }
            .disabled(status == nil || model.isRefreshing || model.requestingPermission != nil)
            .accessibilityIdentifier("settings.permissions.\(permission.rawValue).action")
        }
    }
}
