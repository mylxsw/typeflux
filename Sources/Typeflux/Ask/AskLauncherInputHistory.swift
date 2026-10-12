import Foundation

/// Input only: captured selections, attachments and generated answers never enter this store.
struct AskLauncherInputHistory: Codable, Equatable {
    enum Destination: String, Codable {
        case askAI = "ai"
        case calculation, application, file, keyword, web, unsent
    }

    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var text: String
        var destination: Destination
        var label: String = ""
        var keyword: String?
        var date: Date
    }

    var entries: [Entry] = []
    static let maximumTextLength = 500

    static func identity(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    mutating func record(_ text: String, destination: Destination, label: String = "", keyword: String? = nil,
                         at date: Date = Date(), limit: Int = 100, id: UUID? = nil) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTextLength))
        guard !text.isEmpty, destination != .unsent || text.count >= 2 else { return }
        let identity = Self.identity(text)
        let id = id ?? entries.first { Self.identity($0.text) == identity }?.id ?? UUID()
        entries.removeAll { Self.identity($0.text) == identity }
        entries.insert(Entry(id: id, text: text, destination: destination,
                             label: String(label.prefix(200)), keyword: keyword.map { String($0.prefix(50)) },
                             date: date), at: 0)
        entries = Array(entries.prefix(max(0, min(200, limit))))
    }
}

protocol AskLauncherInputHistoryStorage {
    func read() -> Data?
    func write(_ data: Data)
}

struct DefaultsAskLauncherInputHistoryStorage: AskLauncherInputHistoryStorage {
    static let key = "ask.launcher.inputHistory"
    let defaults: UserDefaults
    func read() -> Data? { defaults.data(forKey: Self.key) }
    func write(_ data: Data) { defaults.set(data, forKey: Self.key) }
}
