import Combine
import Foundation

@MainActor
final class AskLauncherInputHistoryStore: ObservableObject {
    @Published private(set) var history = AskLauncherInputHistory()
    let settings: SettingsStore
    private let storage: any AskLauncherInputHistoryStorage
    private var observer: AnyCancellable?
    private var keys: [UUID: AskSearchKey] = [:]

    init(settings: SettingsStore, storage: (any AskLauncherInputHistoryStorage)? = nil) {
        self.settings = settings
        self.storage = storage ?? DefaultsAskLauncherInputHistoryStorage(defaults: settings.defaults)
        reload()
        observer = NotificationCenter.default.publisher(for: .askLauncherInputHistoryDidChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    var enabled: Bool { settings.askLauncherInputHistoryEnabled }

    func reload() {
        let saved = storage.read().flatMap { try? JSONDecoder().decode(AskLauncherInputHistory.self, from: $0) }
        var cleaned = AskLauncherInputHistory()
        // Apply bounds and deduplication to older or malformed saved data as well.
        for entry in (saved?.entries ?? []).prefix(200).reversed() {
            cleaned.record(entry.text, destination: entry.destination, label: entry.label, keyword: entry.keyword,
                           at: entry.date, limit: settings.askLauncherInputHistoryLimit, id: entry.id)
        }
        history = cleaned
        keys = [:]
        if saved != cleaned { save() }
    }

    func matches(_ filter: String) -> [AskLauncherInputHistory.Entry] {
        guard enabled else { return [] }
        let query = AskLauncherInputHistory.identity(filter)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { entry in
            if entry.text.localizedStandardContains(query) { return true }
            let key = keys[entry.id] ?? AskSearchKey(entry.text)
            keys[entry.id] = key
            return key.pinyin.map { (String(bytes: $0.initials, encoding: .utf8)?.contains(query) ?? false) } ?? false
        }
    }

    func record(_ text: String, destination: AskLauncherInputHistory.Destination, label: String = "",
                keyword: String? = nil, at date: Date = Date()) {
        guard enabled else { return }
        history.record(text, destination: destination, label: label, keyword: keyword, at: date,
                       limit: settings.askLauncherInputHistoryLimit)
        keys = [:]
        save()
    }

    func delete(_ id: UUID) {
        history.entries.removeAll { $0.id == id }
        keys[id] = nil
        save()
    }

    func clear() {
        history.entries = []
        keys = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { storage.write(data) }
    }
}

extension Notification.Name {
    static let askLauncherInputHistoryDidChange = Notification.Name("askLauncherInputHistoryDidChange")
}
