import AppKit
import SwiftUI

struct RecentInputMemoryManagementView: View {
    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAppIdentifier: String?
    @State private var isGlobalSoulSelected = false
    @State private var hoveredFilter: String?
    @State private var query = ""
    @State private var pendingDeletion: PendingDeletion?

    private enum PendingDeletion {
        case soul
        case app(String)
        case memory(UUID)
    }

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
            Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth)
            HStack(spacing: 0) {
                sidebar.frame(width: TFMetrics.paneListWidth)
                Rectangle().fill(TFColors.border).frame(width: TFMetrics.borderWidth)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .background(AskWindowBackdrop())
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(deletionActionTitle, role: .destructive) { performPendingDeletion() }
            Button(L("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            if case let .app(appIdentifier) = pendingDeletion {
                Text(displayName(for: appIdentifier))
            }
        }
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
                TFButton(title: L("settings.advanced.recentInputMemory.close"), systemImage: "xmark",
                         kind: .plain, iconOnly: true) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            TFSearchField(placeholder: L("memory.search"), text: $query, placement: .container,
                          resultCount: viewModel.recentInputMemoryItems.filter {
                              TFSearchMatcher.matches(query, $0.text)
                          }.count, identifier: "settings.memory.search")
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
                TFEmptyState(systemImage: "tray", title: L("settings.advanced.recentInputMemory.empty")) {
                    EmptyView()
                }
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
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13))
                        .foregroundStyle(isSelected ? TFColors.accent : TFColors.textSecondary)
                        .frame(width: 18)
                } else if let appIdentifier {
                    appIcon(for: appIdentifier, size: 18)
                }
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(TFColors.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TFMetrics.paneRowHeight)
            .background(
                isSelected ? TFColors.selection
                    : (hoveredFilter == key ? TFColors.hoverOverlay : Color.clear),
                in: RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hoveredFilter = $0 ? key : nil }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var globalSoulCard: some View {
        TFCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("settings.advanced.globalSoul.manage"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TFColors.textPrimary)
                    Spacer()
                    TFButton(title: L("settings.advanced.globalSoul.delete"), kind: .secondary,
                             destructive: true, size: .small) {
                        pendingDeletion = .soul
                    }
                    .disabled(viewModel.globalSoulMemory == nil)
                }
                .padding(18)
                TFDivider(inset: 18)
                if let soul = viewModel.globalSoulMemory {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(soul.text)
                            .font(.system(size: 13))
                            .foregroundStyle(TFColors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(soul.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(TFColors.textTertiary)
                    }
                    .padding(18)
                } else {
                    Text(L("settings.advanced.globalSoul.empty"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(TFColors.textSecondary)
                        .padding(18)
                }
            }
        }
    }

    private func appCard(for appIdentifier: String) -> some View {
        let memories = viewModel.recentInputMemoryItems.filter {
            $0.appIdentifier == appIdentifier && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
        return TFCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    appIcon(for: appIdentifier, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: appIdentifier))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TFColors.textPrimary)
                        Text(appIdentifier)
                            .font(.system(size: 11))
                            .foregroundStyle(TFColors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(L("settings.advanced.recentInputMemory.appEnabled"))
                        .font(.system(size: 12))
                        .foregroundStyle(TFColors.textSecondary)
                    TFSwitch(title: L("settings.advanced.recentInputMemory.appEnabled"),
                             isOn: Binding(
                                 get: { !viewModel.recentInputMemoryExcludedApps.contains(appIdentifier) },
                                 set: { viewModel.setRecentInputMemoryAllowed($0, appIdentifier: appIdentifier) }
                             ))
                        .disabled(!viewModel.recentInputMemoryEnabled)
                    TFButton(title: L("settings.advanced.recentInputMemory.clearApp"),
                             kind: .secondary, destructive: true, size: .small) {
                        pendingDeletion = .app(appIdentifier)
                    }
                    .disabled(memories.isEmpty)
                }
                .padding(18)
                TFDivider(inset: 18)
                if memories.isEmpty {
                    Text(L("settings.advanced.recentInputMemory.emptyApp"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(TFColors.textSecondary)
                        .padding(18)
                } else {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                        if index > 0 { TFDivider(inset: 18) }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(TFColors.textTertiary)
                                Text(memory.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(TFColors.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Spacer(minLength: 4)
                            TFButton(title: L("settings.advanced.recentInputMemory.deleteItem"),
                                     systemImage: "trash", kind: .plain, destructive: true,
                                     size: .small, iconOnly: true) {
                                pendingDeletion = .memory(memory.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .soul: L("settings.advanced.globalSoul.delete")
        case .app: L("settings.advanced.recentInputMemory.clearApp")
        case .memory: L("settings.advanced.recentInputMemory.deleteItem")
        case nil: ""
        }
    }

    private var deletionActionTitle: String {
        if case .app = pendingDeletion {
            return L("settings.advanced.recentInputMemory.clearApp")
        }
        return L("common.delete")
    }

    private func performPendingDeletion() {
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        switch pendingDeletion {
        case .soul: viewModel.deleteGlobalSoulMemory()
        case let .app(appIdentifier): viewModel.clearRecentInputMemory(appIdentifier: appIdentifier)
        case let .memory(id): viewModel.deleteRecentInputMemory(id: id)
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
