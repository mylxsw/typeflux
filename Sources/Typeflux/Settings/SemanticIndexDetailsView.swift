import AppKit
import SwiftUI

/// Paged view of the durable content-index queue and completed jobs.
struct SemanticIndexDetailsView: View {
    @ObservedObject var service: SemanticFileSearchService
    @Environment(\.dismiss) private var dismiss
    @State private var section: SemanticFileStore.ProcessingSection = .pending
    @State private var offset = 0
    @State private var page: SemanticFileStore.ProcessingPage?
    @State private var loadFailed = false
    @State private var retrying: Set<String> = []
    @State private var retryFailed: Set<String> = []

    private static let pageSize = 50

    private struct PageKey: Equatable {
        let section: SemanticFileStore.ProcessingSection
        let offset: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TFDivider(inset: 0)
            VStack(alignment: .leading, spacing: 16) {
                currentFile
                HStack {
                    TFSegmentedControl(options: [
                        TFOption(.pending, L("semantic.details.pending")),
                        TFOption(.completed, L("semantic.details.completed"))
                    ], selection: sectionSelection, size: .small) { value in
                        "semantic.details.\(value == .pending ? "pending" : "completed")"
                    }
                    Spacer()
                    if let page {
                        Text(L("semantic.details.total", page.total.formatted()))
                            .font(.system(size: 12)).foregroundStyle(TFColors.textTertiary)
                    }
                }
                TFCard {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if let page, page.items.isEmpty {
                                emptyState(L("semantic.details.empty"))
                            } else if let page {
                                ForEach(page.items.indices, id: \.self) { index in
                                    itemRow(page.items[index])
                                    if index < page.items.count - 1 {
                                        TFDivider()
                                    }
                                }
                            } else if loadFailed {
                                emptyState(L("semantic.details.unavailable"))
                            } else {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(20)
        }
        .frame(width: 780, height: min(680, max(500, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .background(AskWindowBackdrop())
        .onAppear {
            if service.phase == .ready {
                section = .completed
            }
        }
        .task(id: PageKey(section: section, offset: offset)) {
            while !Task.isCancelled {
                let next = await service.processingPage(section, offset: offset, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                if let next {
                    page = next; loadFailed = false
                } else {
                    page = nil; loadFailed = true
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("semantic.details.title"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
            Spacer()
            TFButton(title: L("semantic.details.close"), systemImage: "xmark", kind: .plain, iconOnly: true) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var sectionSelection: Binding<SemanticFileStore.ProcessingSection> {
        Binding(get: { section }, set: { value in
            guard section != value else { return }
            section = value; offset = 0; page = nil; loadFailed = false
        })
    }

    private func emptyState(_ title: String) -> some View {
        TFEmptyState(systemImage: "tray", title: title) { EmptyView() }
            .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("semantic.details.historyNote"))
                .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
            Spacer()
            TFButton(title: L("semantic.details.previous"), kind: .secondary, size: .small) {
                offset = max(0, offset - Self.pageSize); page = nil; loadFailed = false
            }
            .disabled(offset == 0)
            Text("\(offset / Self.pageSize + 1)")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(TFColors.textSecondary)
            TFButton(title: L("semantic.details.next"), kind: .secondary, size: .small) {
                offset += Self.pageSize; page = nil; loadFailed = false
            }
            .disabled(page.map { offset + Self.pageSize >= $0.total } ?? true)
        }
    }

    @ViewBuilder private var currentFile: some View {
        if let path = service.currentProcessingPath, service.phase == .indexing || service.phase == .paused {
            HStack(alignment: .top, spacing: 12) {
                TFIconTile(systemImage: "doc.text.magnifyingglass", style: .neutral)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(service.phase == .paused ? "semantic.details.pausedFile" : "semantic.details.current"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(TFColors.textPrimary)
                        .lineLimit(1)
                    Text(AskLauncherSearchSettings.abbreviate((path as NSString).deletingLastPathComponent))
                        .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .tfCardSurface()
        } else {
            Text(L(service.phase == .indexing ? "semantic.details.scanning" : "semantic.details.noCurrent"))
                .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // swiftlint:disable:next function_body_length
    private func itemRow(_ item: SemanticFileStore.ProcessingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TFIconTile(systemImage: symbol(for: item.priority), style: .neutral)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(TFColors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(L("semantic.details.state.\(item.displayState)"))
                        .font(.system(size: 10)).foregroundStyle(TFColors.textSecondary)
                }
                Text(AskLauncherSearchSettings.abbreviate((item.path as NSString).deletingLastPathComponent))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = item.reason {
                    Text(L(SemanticProcessingPresentation.reasonKey(reason)))
                        .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(SemanticProcessingPresentation.progress(item))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if retryFailed.contains(item.path) {
                    Text(L("semantic.details.retryUnavailable"))
                        .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                }
                Text(metadata(for: item))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if item.canRetry {
                TFButton(title: L("semantic.details.retry"), kind: .secondary, size: .small) {
                    retrying.insert(item.path); retryFailed.remove(item.path)
                    let key = PageKey(section: section, offset: offset)
                    Task {
                        let accepted = await service.retryProcessingItem(item)
                        retrying.remove(item.path)
                        if !accepted {
                            retryFailed.insert(item.path)
                        }
                        let next = await service.processingPage(key.section, offset: key.offset, limit: Self.pageSize)
                        guard section == key.section, offset == key.offset else { return }
                        page = next; loadFailed = next == nil
                    }
                }
                .disabled(retrying.contains(item.path) || !service.canRetryProcessingItem(item))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("semantic.details.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }

    private func metadata(for item: SemanticFileStore.ProcessingItem) -> String {
        var parts: [String] = []
        if let bytes = item.bytes {
            parts.append(SemanticFileSearchStatus.size(bytes))
        }
        if let modified = item.modified {
            parts.append(L("semantic.details.modified", modified.formatted(date: .abbreviated, time: .omitted)))
        }
        if let page = item.page, section == .pending {
            parts.append(L("semantic.details.page", page.formatted()))
        }
        if let seconds = item.processingSeconds {
            parts.append(L("semantic.details.duration", Self.duration(seconds)))
        } else if section == .completed {
            parts.append(L("semantic.details.durationUnknown"))
        }
        if let finished = item.completedAt, section == .completed {
            parts.append(finished.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? L("semantic.details.metadataUnknown") : parts.joined(separator: " · ")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if seconds < 1 {
            return "\(max(1, Int((seconds * 1000).rounded())))ms"
        }
        if value < 60 {
            return "\(value)s"
        }
        if value < 3600 {
            return "\(value / 60)m \(value % 60)s"
        }
        return "\(value / 3600)h \((value % 3600) / 60)m"
    }

    private func symbol(for priority: SemanticMediaPriority) -> String {
        switch priority {
        case .document: "doc.text"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        }
    }
}
