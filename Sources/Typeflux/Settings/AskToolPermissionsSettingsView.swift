import SwiftUI
import Combine

struct AskToolPermissionsSettingsView: View {
    let settings: SettingsStore
    @State private var mode = AskPermissionMode.standard
    @State private var query = ""
    @State private var expanded: Set<String> = ["web_browser"]
    @State private var revision = 0

    private var groups: [(tool: String, entries: [AskToolAuthorizationEntry])] {
        let entries = settings.toolPermissionEntries.filter {
            query.isEmpty || ($0.toolTitle + " " + $0.title + " " + $0.id).localizedCaseInsensitiveContains(query)
        }
        let grouped = Dictionary(grouping: entries, by: \.tool)
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard seen.insert(entry.tool).inserted else { return nil }
            return (entry.tool, grouped[entry.tool] ?? [])
        }
    }

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFPaneHeader(systemImage: "checkmark.shield", title: L("agent.permissions.title")) {
                TFButton(title: L("agent.permissions.reset"), size: .small) {
                    settings.resetToolPermissions(mode: mode)
                    revision += 1
                }
            }
            TFSegmentedControl(options: AskPermissionMode.allCases.map { TFOption($0, $0.title) }, selection: $mode)
                .accessibilityIdentifier("agent.permissions.mode")
            TFSearchField(placeholder: L("agent.permissions.search"), text: $query)
            ForEach(groups, id: \.tool) { group in
                TFCard {
                    if group.entries.count == 1, let entry = group.entries.first, entry.action == "*" {
                        permissionRow(entry, title: entry.toolTitle)
                    } else {
                        TFDisclosureRow(title: group.entries.first?.toolTitle ?? group.tool,
                                        isExpanded: Binding(get: { !query.isEmpty || expanded.contains(group.tool) },
                                                            set: { if $0 { expanded.insert(group.tool) } else { expanded.remove(group.tool) } }))
                        if !query.isEmpty || expanded.contains(group.tool) {
                            ForEach(group.entries) { entry in
                                TFDivider.form
                                permissionRow(entry, title: entry.title)
                            }
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askToolCatalogDidChange)
            .merge(with: DistributedNotificationCenter.default().publisher(for: .askToolCatalogDidChange))) { _ in
                settings.defaults.synchronize(); revision += 1
            }
        .onReceive(NotificationCenter.default.publisher(for: .askToolPermissionsDidChange)
            .merge(with: DistributedNotificationCenter.default().publisher(for: .askToolPermissionsDidChange))) { _ in
                settings.defaults.synchronize(); revision += 1
            }
    }
    private func permissionRow(_ entry: AskToolAuthorizationEntry, title: String) -> some View {
        TFFormRow(title: title, detail: entry.detail) {
            TFPopUpButton(title: title,
                          options: AskToolPermission.allCases.map { TFOption($0, $0.title) },
                          selection: Binding(get: { settings.toolPermission(entry, mode: mode) },
                                             set: { settings.setToolPermission($0, entry: entry, mode: mode); revision += 1 }),
                          width: TFMetrics.formControlWidth,
                          identifier: "agent.permissions." + entry.id)
        }
    }

}
