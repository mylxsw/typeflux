import AppKit
import SwiftUI

struct RecentInputMemoryManagementView: View {
    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAppIdentifier: String?
    @State private var isGlobalSoulSelected = false
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
            HStack {
                Text(L("settings.advanced.recentInputMemory.manage"))
                    .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L("settings.advanced.recentInputMemory.close"))
            }
            .padding(StudioTheme.Spacing.large)

            Text(L("memory.recentScope")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            Text(L("memory.boundaries")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            TextField(L("memory.search"), text: $query).padding()
            if let error = viewModel.memoryOperationError {
                Text(error).font(.caption).foregroundStyle(StudioTheme.danger).padding(.horizontal)
            }
            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: StudioTheme.Spacing.small) {
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
                    .frame(maxWidth: .infinity)
                    .padding(StudioTheme.Spacing.large)
                }
                .frame(width: 210)
                .background(StudioTheme.shellSurface)

                Divider()

                ScrollView {
                    if isGlobalSoulSelected {
                        globalSoulCard
                            .padding(StudioTheme.Spacing.large)
                    } else if displayedApplications.isEmpty {
                        Text(L("settings.advanced.recentInputMemory.empty"))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                            ForEach(displayedApplications, id: \.self) { appIdentifier in
                                appCard(for: appIdentifier)
                            }
                        }
                        .padding(StudioTheme.Spacing.large)
                    }
                }
            }
        }
        .frame(width: 820, height: 680)
        .background(StudioTheme.modalSurface)
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

    private func appFilterRow(
        title: String, icon: String?, count: Int, appIdentifier: String?, selectsGlobalSoul: Bool = false
    ) -> some View {
        let isSelected = selectsGlobalSoul ? isGlobalSoulSelected
            : (!isGlobalSoulSelected && selectedAppIdentifier == appIdentifier)
        return Button {
            isGlobalSoulSelected = selectsGlobalSoul
            selectedAppIdentifier = appIdentifier
        } label: {
            HStack(spacing: StudioTheme.Spacing.small) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 22)
                } else if let appIdentifier,
                          let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app")
                        .frame(width: 22)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudioTheme.Spacing.medium)
            .padding(.vertical, StudioTheme.Spacing.small)
            .background(isSelected ? StudioTheme.selectionSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var globalSoulCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                HStack {
                    Text(L("settings.advanced.globalSoul.manage"))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    Spacer()
                    Button(L("settings.advanced.globalSoul.delete"), role: .destructive) {
                        viewModel.deleteGlobalSoulMemory()
                    }
                    .disabled(viewModel.globalSoulMemory == nil)
                }
                Divider()
                if let soul = viewModel.globalSoulMemory {
                    Text(soul.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(soul.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                } else {
                    Text(L("settings.advanced.globalSoul.empty"))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
    }

    private func appCard(for appIdentifier: String) -> some View {
        let memories = viewModel.recentInputMemoryItems.filter {
            $0.appIdentifier == appIdentifier && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
        return StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                HStack(spacing: StudioTheme.Spacing.medium) {
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: appIdentifier))
                            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                        Text(appIdentifier)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    Spacer()
                }

                HStack {
                    Spacer()
                    Toggle(
                        L("settings.advanced.recentInputMemory.appEnabled"),
                        isOn: Binding(
                            get: { !viewModel.recentInputMemoryExcludedApps.contains(appIdentifier) },
                            set: { viewModel.setRecentInputMemoryAllowed($0, appIdentifier: appIdentifier) }
                        )
                    )
                    .disabled(!viewModel.recentInputMemoryEnabled)
                    Button(L("settings.advanced.recentInputMemory.clearApp"), role: .destructive) {
                        viewModel.clearRecentInputMemory(appIdentifier: appIdentifier)
                    }
                    .disabled(memories.isEmpty)
                }

                Divider()

                if memories.isEmpty {
                    Text(L("settings.advanced.recentInputMemory.emptyApp"))
                        .foregroundStyle(StudioTheme.textSecondary)
                } else {
                    ForEach(memories) { memory in
                        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                                Text(memory.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.studioBody(StudioTheme.Typography.caption))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                Text(memory.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button(role: .destructive) {
                                viewModel.deleteRecentInputMemory(id: memory.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("settings.advanced.recentInputMemory.deleteItem"))
                        }
                        if memory.id != memories.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
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
