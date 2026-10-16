import AppKit
import SwiftUI
import TypefluxMediaProtocol
import UniformTypeIdentifiers

/// Application icons survive launcher sessions. File and folder icons are kept
/// only while the launcher is visible and are versioned by the search index.
@MainActor
final class AskLauncherIconCache {
    private struct Key: Hashable {
        let icon: MediaNativeIcon
        let revision: Date?
        var isPrivate: Bool { !AskLauncherIconCache.eligible(icon) }
        init(_ icon: MediaNativeIcon, revision: Date? = nil) {
            self.icon = icon
            self.revision = AskLauncherIconCache.eligible(icon) ? nil : revision
        }
    }
    private struct Entry {
        let result: AskFilePreviewPDF.Result
        let expires: Date
    }
    private struct Pending {
        let task: Task<AskFilePreviewPDF.Result, Error>
        var clients: Set<UUID>
    }

    private var entries: [Key: Entry] = [:]
    private var applicationOrder: [Key] = []
    private var fileOrder: [Key] = []
    private var pending: [Key: Pending] = [:]
    private var prefetchTasks: [Key: (id: UUID, task: Task<Void, Never>)] = [:]
    private var applicationPrefetch: Set<Key> = []
    private var filePrefetch: Set<Key> = []
    private var generation = UUID()
    private var fileGeneration = UUID()
    private let decode: AskNativeIconDecoding
    private let capacity: Int
    private let fileCapacity: Int
    private let lifetime: TimeInterval
    private let immediateLookup: @MainActor (MediaNativeIcon, Bool) -> NSImage?

    init(capacity: Int = 64, fileCapacity: Int = 48, lifetime: TimeInterval = 300,
         immediateLookup: @escaping @MainActor (MediaNativeIcon, Bool) -> NSImage? = AskLauncherIconCache.systemIcon,
         decode: @escaping AskNativeIconDecoding = { try await AskFinderIcon.decode($0) }) {
        self.capacity = capacity; self.fileCapacity = fileCapacity
        self.lifetime = lifetime; self.immediateLookup = immediateLookup; self.decode = decode
    }

    nonisolated static func eligible(_ icon: MediaNativeIcon) -> Bool {
        icon.kind == .application ||
            (icon.kind == .file && ["app", "appex", "prefpane"].contains(
                URL(fileURLWithPath: icon.value).pathExtension.lowercased()))
    }

    func cached(_ icon: MediaNativeIcon, revision: Date? = nil) -> AskFilePreviewPDF.Result? {
        guard Self.eligible(icon, revision: revision) else { return nil }
        let key = Key(icon, revision: revision)
        guard let entry = entries[key] else { return nil }
        guard entry.expires > Date() else {
            entries[key] = nil
            if key.isPrivate { fileOrder.removeAll { $0 == key } }
            else { applicationOrder.removeAll { $0 == key } }
            return nil
        }
        return entry.result
    }

    nonisolated static func eligible(_ icon: MediaNativeIcon, revision: Date?) -> Bool {
        eligible(icon) || (revision != nil && icon.kind == .file && icon.value.hasPrefix("/"))
    }

    /// Resolve the visible search row before publication. Application bundles
    /// keep their exact icon; documents use their system type icon, so reading a
    /// slow or malformed file never blocks the launcher.
    func immediate(_ icon: MediaNativeIcon, revision: Date? = nil, folder: Bool = false) -> AskFilePreviewPDF.Result? {
        guard Self.eligible(icon, revision: revision) else { return nil }
        if let result = cached(icon, revision: revision) { return result }
        guard (try? icon.validate()) != nil, let image = immediateLookup(icon, folder),
              let result = Self.rasterized(image) else { return nil }
        remember(result, for: Key(icon, revision: revision))
        return result
    }

    private static func systemIcon(_ icon: MediaNativeIcon, folder: Bool) -> NSImage? {
        switch icon.kind {
        case .application:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: icon.value) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .file:
            if eligible(icon) { return NSWorkspace.shared.icon(forFile: icon.value) }
            if folder { return NSWorkspace.shared.icon(for: .folder) }
            let type = UTType(filenameExtension: URL(fileURLWithPath: icon.value).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        case .fileExtension, .type:
            return nil
        }
    }

    private static func rasterized(_ image: NSImage) -> AskFilePreviewPDF.Result? {
        var bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        guard let source = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 56, height: 56, bitsPerComponent: 8, bytesPerRow: 224,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: bounds)
        guard let raster = context.makeImage() else { return nil }
        return .init(images: [raster], numbers: [], pages: 0)
    }

    func load(_ icon: MediaNativeIcon, revision: Date? = nil) async throws -> AskFilePreviewPDF.Result {
        guard Self.eligible(icon, revision: revision) else { throw MediaFailure.invalidProtocol }
        try Task.checkCancellation()
        if let result = cached(icon, revision: revision) { return result }
        let key = Key(icon, revision: revision)
        let currentGeneration = generation
        let currentFileGeneration = fileGeneration
        let client = UUID()
        let task: Task<AskFilePreviewPDF.Result, Error>
        if var current = pending[key] {
            current.clients.insert(client); pending[key] = current; task = current.task
        } else {
            task = Task { [decode] in try await decode(icon) }
            pending[key] = Pending(task: task, clients: [client])
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                guard generation == currentGeneration,
                      !key.isPrivate || fileGeneration == currentFileGeneration else { throw CancellationError() }
                guard result.images.count == 1, let image = result.images.first,
                      image.width > 0, image.height > 0, image.width <= 56, image.height <= 56 else {
                    throw MediaFailure.invalidProtocol
                }
                remember(result, for: key)
                release(key, client: client)
                return result
            } catch {
                release(key, client: client)
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key, client: client) }
        }
    }

    /// Replace stale-query prefetches. Visible rows sharing a request keep it alive.
    func prefetch(_ icons: [MediaNativeIcon]) {
        let ordered = Array(icons.filter(Self.eligible).prefix(12)).map { Key($0) }
        updatePrefetch(ordered, privateFiles: false)
    }

    func prefetchFiles(_ hits: [AskFileHit]) {
        // File mode can show more rows than mixed search; include the first folders.
        let folders = Array(hits.filter(\.isFolder).prefix(3))
        let candidates = Array(hits.prefix(12)) + folders
        let ordered = candidates.map { Key(.init(kind: .file, value: $0.path), revision: $0.modified) }
        let folderKeys = Set(folders.map { Key(.init(kind: .file, value: $0.path), revision: $0.modified) })
        var seen: Set<Key> = []
        updatePrefetch(ordered.filter { seen.insert($0).inserted }, privateFiles: true, folders: folderKeys)
    }

    private func updatePrefetch(_ ordered: [Key], privateFiles: Bool, folders: Set<Key> = []) {
        let wanted = Set(ordered)
        let previous = privateFiles ? filePrefetch : applicationPrefetch
        for key in previous.subtracting(wanted) {
            prefetchTasks[key]?.task.cancel(); prefetchTasks[key] = nil
        }
        if privateFiles { filePrefetch = wanted } else { applicationPrefetch = wanted }
        for key in ordered where immediate(key.icon, revision: key.revision, folder: folders.contains(key)) == nil
            && prefetchTasks[key] == nil {
            let id = UUID()
            let task = Task { [weak self] in
                _ = try? await self?.load(key.icon, revision: key.revision)
                if self?.prefetchTasks[key]?.id == id { self?.prefetchTasks[key] = nil }
            }
            prefetchTasks[key] = (id, task)
        }
    }

    func cancelPrefetch() {
        prefetchTasks.values.forEach { $0.task.cancel() }
        prefetchTasks.removeAll()
        applicationPrefetch.removeAll(); filePrefetch.removeAll()
    }

    func clearFiles() {
        fileGeneration = UUID()
        for key in filePrefetch { prefetchTasks[key]?.task.cancel(); prefetchTasks[key] = nil }
        filePrefetch.removeAll()
        for (key, value) in Array(pending) where key.isPrivate {
            value.task.cancel(); pending[key] = nil
        }
        for key in fileOrder { entries[key] = nil }
        fileOrder.removeAll()
    }

    func clear() {
        generation = UUID()
        cancelPrefetch()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(); entries.removeAll()
        applicationOrder.removeAll(); fileOrder.removeAll()
    }

    private func release(_ key: Key, client: UUID) {
        guard var current = pending[key], current.clients.remove(client) != nil else { return }
        if current.clients.isEmpty { pending[key] = nil; current.task.cancel() }
        else { pending[key] = current }
    }

    private func remember(_ result: AskFilePreviewPDF.Result, for key: Key) {
        entries[key] = Entry(result: result, expires: Date().addingTimeInterval(lifetime))
        if key.isPrivate {
            fileOrder.removeAll { $0 == key }; fileOrder.append(key)
            while fileOrder.count > fileCapacity { entries[fileOrder.removeFirst()] = nil }
        } else {
            applicationOrder.removeAll { $0 == key }; applicationOrder.append(key)
            while applicationOrder.count > capacity { entries[applicationOrder.removeFirst()] = nil }
        }
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
