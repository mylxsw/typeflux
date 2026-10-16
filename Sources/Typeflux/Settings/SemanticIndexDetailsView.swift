import AppKit
import SwiftUI

/// Paged, read-only view of the durable content-index queue and completed jobs.
struct SemanticIndexDetailsView: View {
    @ObservedObject var service: SemanticFileSearchService
    @Environment(\.dismiss) private var dismiss
    @State private var section: SemanticFileStore.ProcessingSection = .pending
    @State private var offset = 0
    @State private var page: SemanticFileStore.ProcessingPage?
    @State private var loadFailed = false

    private static let pageSize = 50

    private struct PageKey: Equatable {
        let section: SemanticFileStore.ProcessingSection
        let offset: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("semantic.details.title"))
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                Spacer()
                Button(L("semantic.details.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            currentFile
            HStack(spacing: 8) {
                sectionButton(.pending, title: L("semantic.details.pending"))
                sectionButton(.completed, title: L("semantic.details.completed"))
                Spacer()
                if let page {
                    Text(L("semantic.details.total", page.total.formatted()))
                        .font(.system(size: 12)).foregroundStyle(TFColors.textTertiary)
                }
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let page, page.items.isEmpty {
                        Text(L("semantic.details.empty"))
                            .font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let page {
                        ForEach(page.items) { item in
                            itemRow(item)
                            Divider()
                        }
                    } else if loadFailed {
                        Text(L("semantic.details.unavailable"))
                            .font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }
            .frame(minHeight: 300)
            HStack {
                Text(L("semantic.details.historyNote"))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                Spacer()
                Button(L("semantic.details.previous")) {
                    offset = max(0, offset - Self.pageSize); page = nil; loadFailed = false
                }
                    .disabled(offset == 0)
                Text("\(offset / Self.pageSize + 1)")
                    .monospacedDigit().foregroundStyle(TFColors.textSecondary)
                Button(L("semantic.details.next")) { offset += Self.pageSize; page = nil; loadFailed = false }
                    .disabled(page.map { offset + Self.pageSize >= $0.total } ?? true)
            }
            .font(.system(size: 12))
        }
        .padding(22)
        .frame(minWidth: 700, minHeight: 580)
        .onAppear {
            if service.phase == .ready { section = .completed }
        }
        .task(id: PageKey(section: section, offset: offset)) {
            while !Task.isCancelled {
                let next = await service.processingPage(section, offset: offset, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                if let next { page = next; loadFailed = false } else { loadFailed = true }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder private var currentFile: some View {
        if let path = service.currentProcessingPath, (service.phase == .indexing || service.phase == .paused) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(TFColors.raised, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(L(service.phase == .indexing ? "semantic.details.scanning" : "semantic.details.noCurrent"))
                .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionButton(_ value: SemanticFileStore.ProcessingSection, title: String) -> some View {
        Button(title) {
            guard section != value else { return }
            section = value; offset = 0; page = nil; loadFailed = false
        }
        .font(.system(size: 12, weight: section == value ? .semibold : .regular))
        .foregroundStyle(section == value ? TFColors.accent : TFColors.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(section == value ? TFColors.selection : TFColors.raised,
                    in: RoundedRectangle(cornerRadius: 8))
        .buttonStyle(.plain)
    }

    private func itemRow(_ item: SemanticFileStore.ProcessingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: item.priority))
                .font(.system(size: 17)).foregroundStyle(TFColors.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(TFColors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if section == .completed {
                        Text(L("semantic.details.state.\(item.state)"))
                            .font(.system(size: 10)).foregroundStyle(TFColors.textSecondary)
                    }
                }
                Text(AskLauncherSearchSettings.abbreviate((item.path as NSString).deletingLastPathComponent))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text(metadata(for: item))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("semantic.details.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }

    private func metadata(for item: SemanticFileStore.ProcessingItem) -> String {
        var parts: [String] = []
        if let bytes = item.bytes { parts.append(SemanticFileSearchStatus.size(bytes)) }
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
        if seconds < 1 { return "\(max(1, Int((seconds * 1_000).rounded())))ms" }
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(value % 60)s" }
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
