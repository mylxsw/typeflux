import Foundation

/// Input history stays in the app's local defaults; it has no cloud sync representation.
@MainActor
final class AskTranslationHistory: ObservableObject {
    static let key = "ask.translation.history.v1"
    @Published private(set) var entries: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = Array((defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.isEmpty }.prefix(100))
    }

    func record(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.removeAll { $0 == text }
        entries.insert(String(text.prefix(64000)), at: 0)
        entries = Array(entries.prefix(100))
        defaults.set(entries, forKey: Self.key)
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: Self.key)
    }
}
