import Combine
import Foundation

/// State and keyboard behavior of the clipboard panel. Holds no AppKit objects, so the
/// panel's logic is tested without a window; actions are forwarded to `onAction`.
final class ClipboardPanelModel: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var visibleEntries: [ClipboardEntry] = []
    @Published var category: ClipboardCategory = .all {
        didSet { if category != oldValue { refilter(resetSelection: true) } }
    }

    @Published var query = "" {
        didSet { if query != oldValue { refilter(resetSelection: true) } }
    }

    @Published var selectedIndex = 0
    @Published private(set) var notice: String?

    var onAction: ((ClipboardEntryAction, ClipboardEntry) -> Void)?
    var onDismiss: (() -> Void)?
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var now: () -> Date = Date.init

    private var noticeGeneration = 0

    var selectedEntry: ClipboardEntry? {
        visibleEntries.indices.contains(selectedIndex) ? visibleEntries[selectedIndex] : nil
    }

    /// Starts a new session: all entries, no search, first row selected.
    func reset(entries: [ClipboardEntry]) {
        self.entries = entries
        notice = nil
        query = ""
        category = .all
        refilter(resetSelection: true)
    }

    /// Replaces the entries after an edit, keeping the selection on the same row when it still exists.
    func replaceEntries(_ entries: [ClipboardEntry]) {
        let selectedID = selectedEntry?.id
        let previousIndex = selectedIndex
        self.entries = entries
        refilter(resetSelection: false)
        if let selectedID, let index = visibleEntries.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = clampedIndex(previousIndex)
        }
    }

    func moveSelection(by delta: Int) {
        selectedIndex = clampedIndex(selectedIndex + delta)
    }

    func select(index: Int) {
        guard visibleEntries.indices.contains(index) else { return }
        selectedIndex = index
    }

    func cycleCategory(forward: Bool) {
        let all = ClipboardCategory.allCases
        let current = all.firstIndex(of: category) ?? 0
        category = all[(current + (forward ? 1 : all.count - 1)) % all.count]
    }

    func section(for entry: ClipboardEntry) -> ClipboardFeed.Section {
        ClipboardFeed.section(for: entry, now: now())
    }

    /// True when the files behind an entry were moved or deleted since they were copied.
    func isMissing(_ entry: ClipboardEntry) -> Bool {
        if let imagePath = entry.imagePath { return !fileExists(imagePath) }
        return entry.filePaths.contains { !fileExists($0) }
    }

    func actions(for entry: ClipboardEntry) -> [ClipboardEntryAction] {
        ClipboardEntryAction.available(for: entry)
    }

    func isEnabled(_ action: ClipboardEntryAction, for entry: ClipboardEntry) -> Bool {
        !(action.requiresContent && isMissing(entry))
    }

    /// Runs an action on the entry at `index`, or on the selected entry.
    func perform(_ action: ClipboardEntryAction, at index: Int? = nil) {
        if let index { select(index: index) }
        guard let entry = selectedEntry, actions(for: entry).contains(action) else { return }
        guard isEnabled(action, for: entry) else {
            showNotice(L("clipboard.notice.missingFile"))
            return
        }
        onAction?(action, entry)
    }

    /// `⌘1`…`⌘9` paste the n-th visible row.
    func quickPaste(number: Int) {
        guard (1 ... 9).contains(number), visibleEntries.indices.contains(number - 1) else { return }
        perform(.paste, at: number - 1)
    }

    /// Escape clears the search first, then closes the panel.
    func cancel() {
        if query.isEmpty {
            onDismiss?()
        } else {
            query = ""
        }
    }

    func showNotice(_ message: String) {
        notice = message
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, noticeGeneration == generation else { return }
            notice = nil
        }
    }

    private func refilter(resetSelection: Bool) {
        visibleEntries = ClipboardFeed.filter(entries, category: category, query: query)
        selectedIndex = resetSelection ? 0 : clampedIndex(selectedIndex)
    }

    private func clampedIndex(_ index: Int) -> Int {
        max(0, min(index, visibleEntries.count - 1))
    }
}
