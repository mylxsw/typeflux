import AppKit
import SwiftUI
import TypefluxMediaProtocol

/// A small launcher-owned cache for application bundles only. Other file icons
/// remain scoped to their rows, and a hidden launcher never displays cached pixels.
@MainActor
final class AskLauncherIconCache {
    private struct Entry {
        let result: AskFilePreviewPDF.Result
        let expires: Date
    }
    private struct Pending {
        let task: Task<AskFilePreviewPDF.Result, Error>
        var clients: Set<UUID>
    }

    private var entries: [MediaNativeIcon: Entry] = [:]
    private var order: [MediaNativeIcon] = []
    private var pending: [MediaNativeIcon: Pending] = [:]
    private var prefetchTasks: [MediaNativeIcon: (id: UUID, task: Task<Void, Never>)] = [:]
    private var generation = UUID()
    private let decode: AskNativeIconDecoding
    private let capacity: Int
    private let lifetime: TimeInterval

    init(capacity: Int = 64, lifetime: TimeInterval = 300,
         decode: @escaping AskNativeIconDecoding = { try await AskFinderIcon.decode($0) }) {
        self.capacity = capacity; self.lifetime = lifetime; self.decode = decode
    }

    nonisolated static func eligible(_ icon: MediaNativeIcon) -> Bool {
        icon.kind == .application ||
            (icon.kind == .file && URL(fileURLWithPath: icon.value).pathExtension.lowercased() == "app")
    }

    func cached(_ icon: MediaNativeIcon) -> AskFilePreviewPDF.Result? {
        guard Self.eligible(icon), let entry = entries[icon] else { return nil }
        guard entry.expires > Date() else { entries[icon] = nil; order.removeAll { $0 == icon }; return nil }
        return entry.result
    }

    func load(_ icon: MediaNativeIcon) async throws -> AskFilePreviewPDF.Result {
        guard Self.eligible(icon) else { throw MediaFailure.invalidProtocol }
        try Task.checkCancellation()
        if let result = cached(icon) { return result }
        let currentGeneration = generation
        let client = UUID()
        let task: Task<AskFilePreviewPDF.Result, Error>
        if var current = pending[icon] {
            current.clients.insert(client); pending[icon] = current; task = current.task
        } else {
            task = Task { [decode] in try await decode(icon) }
            pending[icon] = Pending(task: task, clients: [client])
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                guard result.images.count == 1, let image = result.images.first,
                      image.width > 0, image.height > 0, image.width <= 56, image.height <= 56 else {
                    throw MediaFailure.invalidProtocol
                }
                entries[icon] = Entry(result: result, expires: Date().addingTimeInterval(lifetime))
                order.removeAll { $0 == icon }; order.append(icon)
                while order.count > capacity { entries[order.removeFirst()] = nil }
                release(icon, client: client)
                return result
            } catch {
                release(icon, client: client)
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(icon, client: client) }
        }
    }

    /// Replace stale-query prefetches. Visible rows sharing a request keep it alive.
    func prefetch(_ icons: [MediaNativeIcon]) {
        let ordered = Array(icons.filter(Self.eligible).prefix(3))
        let wanted = Set(ordered)
        for (icon, entry) in Array(prefetchTasks) where !wanted.contains(icon) {
            entry.task.cancel(); prefetchTasks[icon] = nil
        }
        for icon in ordered where cached(icon) == nil && prefetchTasks[icon] == nil {
            let id = UUID()
            let task = Task { [weak self] in
                _ = try? await self?.load(icon)
                if self?.prefetchTasks[icon]?.id == id { self?.prefetchTasks[icon] = nil }
            }
            prefetchTasks[icon] = (id, task)
        }
    }

    func cancelPrefetch() {
        prefetchTasks.values.forEach { $0.task.cancel() }
        prefetchTasks.removeAll()
    }

    func clear() {
        generation = UUID()
        cancelPrefetch()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(); entries.removeAll(); order.removeAll()
    }

    private func release(_ icon: MediaNativeIcon, client: UUID) {
        guard var current = pending[icon], current.clients.remove(client) != nil else { return }
        if current.clients.isEmpty { pending[icon] = nil; current.task.cancel() }
        else { pending[icon] = current }
    }
}

private struct AskLauncherIconCacheKey: EnvironmentKey {
    static let defaultValue: AskLauncherIconCache? = nil
}

extension EnvironmentValues {
    var askLauncherIconCache: AskLauncherIconCache? {
        get { self[AskLauncherIconCacheKey.self] }
        set { self[AskLauncherIconCacheKey.self] = newValue }
    }
}
