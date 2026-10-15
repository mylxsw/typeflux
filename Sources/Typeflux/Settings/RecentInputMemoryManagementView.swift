import AppKit
import SwiftUI

struct RecentInputMemoryManagementView: View {
    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAppIdentifier: String?
    @State private var isGlobalSoulSelected = false
    @State private var hoveredFilter: String?
    @State private var query = ""

    private var applications: [String] {
        let identifiers = Set(viewModel.recentInputMemoryApplications)
            .union(selectedAppIdentifier.map { [$0] } ?? [])
        return identifiers.sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private var displayedApplications: [String] {
        selectedAppIdentifier.map { [$0] } ?? applications
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ModelVisualStyle.border).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 210)
                Rectangle().fill(ModelVisualStyle.border).frame(width: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .background(ModelVisualStyle.canvas)
        .onAppear { viewModel.refreshRecentInputMemoryApplications() }
        .onReceive(NotificationCenter.default.publisher(for: .globalSoulDidChange)) { _ in
            viewModel.refreshRecentInputMemoryApplications()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDidLogin)) { _ in
            viewModel.refreshRecentInputMemoryApplications()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDidLogout)) { _ in
            viewModel.refreshRecentInputMemoryApplications()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(L("settings.advanced.recentInputMemory.manage"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                AgentSettingsIconButton(systemImage: "xmark",
                                        help: L("settings.advanced.recentInputMemory.close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("memory.recentScope"))
                Text(L("memory.boundaries"))
            }
            .font(.system(size: 12))
            .foregroundStyle(StudioTheme.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            SettingsSearchBox(placeholder: L("memory.search"), text: $query, width: nil,
                              fieldIdentifier: "settings.memory.search")
            if let error = viewModel.memoryOperationError {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 4) {
                appFilterRow(
                    title: L("settings.advanced.globalSoul.manage"),
                    icon: "sparkles.rectangle.stack",
                    count: viewModel.globalSoulMemory == nil ? 0 : 1,
                    appIdentifier: nil,
                    selectsGlobalSoul: true
                )
                appFilterRow(
                    title: L("settings.advanced.recentInputMemory.allApps"),
                    icon: "square.grid.2x2",
                    count: viewModel.recentInputMemoryItems.count,
                    appIdentifier: nil
                )
                ForEach(applications, id: \.self) { appIdentifier in
                    appFilterRow(
                        title: displayName(for: appIdentifier),
                        icon: nil,
                        count: viewModel.recentInputMemoryItems.filter {
                            $0.appIdentifier == appIdentifier
                        }.count,
                        appIdentifier: appIdentifier
                    )
                }
            }
            .padding(12)
        }
        .background(StudioTheme.surfaceMuted)
    }

    private var content: some View {
        ScrollView {
            if isGlobalSoulSelected {
                globalSoulCard.padding(20)
            } else if displayedApplications.isEmpty {
                emptyState(L("settings.advanced.recentInputMemory.empty"))
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(displayedApplications, id: \.self) { appIdentifier in
                        appCard(for: appIdentifier)
                    }
                }
                .padding(20)
            }
        }
    }

    private func appFilterRow(
        title: String, icon: String?, count: Int, appIdentifier: String?, selectsGlobalSoul: Bool = false
    ) -> some View {
        let isSelected = selectsGlobalSoul ? isGlobalSoulSelected
            : (!isGlobalSoulSelected && selectedAppIdentifier == appIdentifier)
        let key = selectsGlobalSoul ? "soul" : (appIdentifier ?? "all")
        return Button {
            isGlobalSoulSelected = selectsGlobalSoul
            selectedAppIdentifier = appIdentifier
        } label: {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 14)).frame(width: 22)
                } else if let appIdentifier {
                    appIcon(for: appIdentifier, size: 22)
                }
                Text(title).font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            .foregroundStyle(isSelected ? ModelVisualStyle.accent : StudioTheme.textPrimary)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 38)
            .background(
                isSelected ? ModelVisualStyle.accent.opacity(0.14)
                    : (hoveredFilter == key ? ModelVisualStyle.control : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hoveredFilter = $0 ? key : nil }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var globalSoulCard: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("settings.advanced.globalSoul.manage"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer()
                    TFButton(title: L("settings.advanced.globalSoul.delete"), kind: .secondary,
                             destructive: true, size: .small) {
                        viewModel.deleteGlobalSoulMemory()
                    }
                    .disabled(viewModel.globalSoulMemory == nil)
                }
                .padding(18)
                ModelRowDivider(leading: 18)
                if let soul = viewModel.globalSoulMemory {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(soul.text)
                            .font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(soul.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(18)
                } else {
                    Text(L("settings.advanced.globalSoul.empty"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(18)
                }
            }
        }
    }

    private func appCard(for appIdentifier: String) -> some View {
        let memories = viewModel.recentInputMemoryItems.filter {
            $0.appIdentifier == appIdentifier && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
        return ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    appIcon(for: appIdentifier, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: appIdentifier))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(appIdentifier)
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle(
                        L("settings.advanced.recentInputMemory.appEnabled"),
                        isOn: Binding(
                            get: { !viewModel.recentInputMemoryExcludedApps.contains(appIdentifier) },
                            set: { viewModel.setRecentInputMemoryAllowed($0, appIdentifier: appIdentifier) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!viewModel.recentInputMemoryEnabled)
                    TFButton(title: L("settings.advanced.recentInputMemory.clearApp"),
                             kind: .secondary, destructive: true, size: .small) {
                        viewModel.clearRecentInputMemory(appIdentifier: appIdentifier)
                    }
                    .disabled(memories.isEmpty)
                }
                .padding(18)
                ModelRowDivider(leading: 18)
                if memories.isEmpty {
                    Text(L("settings.advanced.recentInputMemory.emptyApp"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(18)
                } else {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                        if index > 0 { ModelRowDivider(leading: 18) }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                Text(memory.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Spacer(minLength: 4)
                            AgentSettingsIconButton(systemImage: "trash",
                                                    help: L("settings.advanced.recentInputMemory.deleteItem"),
                                                    role: .destructive) {
                                viewModel.deleteRecentInputMemory(id: memory.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func emptyState(_ title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(StudioTheme.textTertiary)
            Text(title).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
        }
    }

    private func appIcon(for appIdentifier: String, size: CGFloat) -> some View {
        Group {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }

    private func displayName(for appIdentifier: String) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier) else {
            return appIdentifier
        }
        return (Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
    }
}
