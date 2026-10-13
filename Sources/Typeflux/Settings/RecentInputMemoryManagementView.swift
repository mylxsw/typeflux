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
                    .font(.system(.title3, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L("settings.advanced.recentInputMemory.close"))
            }
            .padding(18)

            Text(L("memory.recentScope")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            Text(L("memory.boundaries")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            TextField(L("memory.search"), text: $query).padding()
            if let error = viewModel.memoryOperationError {
                Text(error).font(.caption).foregroundStyle(TypefluxColor.danger.color).padding(.horizontal)
            }
            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 10) {
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
                    .padding(18)
                }
                .frame(width: 210)
                .background(TypefluxColor.contentBackground.color)

                Divider()

                ScrollView {
                    if isGlobalSoulSelected {
                        globalSoulCard
                            .padding(18)
                    } else if displayedApplications.isEmpty {
                        Text(L("settings.advanced.recentInputMemory.empty"))
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayedApplications, id: \.self) { appIdentifier in
                                appCard(for: appIdentifier)
                            }
                        }
                        .padding(18)
                    }
                }
            }
        }
        .frame(width: 820, height: 680)
        .background(TypefluxColor.windowBackground.color)
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
            HStack(spacing: 10) {
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
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? TypefluxColor.selection.color.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var globalSoulCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("settings.advanced.globalSoul.manage"))
                        .font(.system(.body, weight: .semibold))
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
                        .font(.system(.subheadline))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                } else {
                    Text(L("settings.advanced.globalSoul.empty"))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
        }
    }

    private func appCard(for appIdentifier: String) -> some View {
        let memories = viewModel.recentInputMemoryItems.filter {
            $0.appIdentifier == appIdentifier && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
        return StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: appIdentifier))
                            .font(.system(.body, weight: .semibold))
                        Text(appIdentifier)
                            .font(.system(.subheadline))
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                } else {
                    ForEach(memories) { memory in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(memory.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(.subheadline))
                                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
