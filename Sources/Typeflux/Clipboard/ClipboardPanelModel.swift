import Combine
import Foundation

/// State and keyboard behavior of the clipboard panel. Holds no AppKit objects, so the
/// panel's logic is tested without a window; actions are forwarded to `onAction`.
final class ClipboardPanelModel: ObservableObject {
    /// One list row: the entry, its position among the visible entries and, on the first row of
    /// a section, the section header. Built once per filter change, never while rendering.
    struct Row: Identifiable, Equatable {
        let entry: ClipboardEntry
        let index: Int
        let header: ClipboardFeed.Section?

        var id: String { entry.id }
    }

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var visibleEntries: [ClipboardEntry] = []
    @Published private(set) var rows: [Row] = []
    @Published var category: ClipboardCategory = .all {
        didSet { if category != oldValue { refilter(resetSelection: true) } }
    }

    @Published var query = "" {
        didSet { if query != oldValue { refilter(resetSelection: true) } }
    }

    @Published var selectedIndex = 0 {
        didSet { if selectedIndex != oldValue { schedulePreview() } }
    }

    @Published private(set) var notice: String?
    /// Whether the side preview pane is shown.
    @Published var showsPreview = false {
        didSet {
            guard showsPreview != oldValue else { return }
            previewEntry = showsPreview ? selectedEntry : nil
            onPreviewVisibilityChange?(showsPreview)
        }
    }

    /// The entry the preview pane shows. Trails the selection by `previewDelay`, so holding an
    /// arrow key moves the highlight without decoding a large preview for every row passed.
    @Published private(set) var previewEntry: ClipboardEntry?
    /// Index of the first row fully inside the list's viewport; `⌘1` pastes it.
    @Published private(set) var firstVisibleIndex = 0
    /// Bumped when the list should scroll back to its first row, e.g. after a new search.
    @Published private(set) var scrollToTopRequest = 0

    var onAction: ((ClipboardEntryAction, ClipboardEntry) -> Void)?
    var onDismiss: (() -> Void)?
    var onPreviewVisibilityChange: ((Bool) -> Void)?
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var now: () -> Date = Date.init
    var previewDelay: TimeInterval = 0.12

    private var noticeGeneration = 0
    private var previewWorkItem: DispatchWorkItem?
    /// Whether an entry's files are gone, checked once per entry per session instead of on every redraw.
    private var missingCache: [String: Bool] = [:]
    /// Lowercase-insensitive search text per entry ID, built once per entry list.
    private var searchIndex: [String: String] = [:]

    var selectedEntry: ClipboardEntry? {
        visibleEntries.indices.contains(selectedIndex) ? visibleEntries[selectedIndex] : nil
    }

    /// Starts a new session: all entries, no search, first row selected.
    func reset(entries: [ClipboardEntry]) {
        missingCache = [:]
        setEntries(entries)
        notice = nil
        query = ""
        category = .all
        refilter(resetSelection: true)
    }

    /// Replaces the entries after an edit, keeping the selection on the same row when it still exists.
    func replaceEntries(_ entries: [ClipboardEntry]) {
        guard entries != self.entries else { return }
        let selectedID = selectedEntry?.id
        let previousIndex = selectedIndex
        missingCache = [:]
        setEntries(entries)
        refilter(resetSelection: false)
        if let selectedID, let index = visibleEntries.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = clampedIndex(previousIndex)
        }
        refreshPreviewNow()
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

    func togglePreview() {
        showsPreview.toggle()
    }

    func section(for entry: ClipboardEntry) -> ClipboardFeed.Section {
        ClipboardFeed.section(for: entry, now: now())
    }

    /// True when the files behind an entry were moved or deleted since they were copied. Checks the
    /// disk every time; actions use it so they never act on a file that just disappeared.
    func isMissing(_ entry: ClipboardEntry) -> Bool {
        if let imagePath = entry.imagePath { return !fileExists(imagePath) }
        return entry.filePaths.contains { !fileExists($0) }
    }

    /// `isMissing` remembered for the session; rows and menus use it while rendering.
    func isMarkedMissing(_ entry: ClipboardEntry) -> Bool {
        guard entry.imagePath != nil || !entry.filePaths.isEmpty else { return false }
        if let cached = missingCache[entry.id] { return cached }
        let missing = isMissing(entry)
        missingCache[entry.id] = missing
        return missing
    }

    func actions(for entry: ClipboardEntry) -> [ClipboardEntryAction] {
        ClipboardEntryAction.available(for: entry)
    }

    func isEnabled(_ action: ClipboardEntryAction, for entry: ClipboardEntry) -> Bool {
        !(action.requiresContent && isMarkedMissing(entry))
    }

    /// Runs an action on the entry at `index`, or on the selected entry.
    func perform(_ action: ClipboardEntryAction, at index: Int? = nil) {
        if let index { select(index: index) }
        guard let entry = selectedEntry, actions(for: entry).contains(action) else { return }
        if action.requiresContent {
            let missing = isMissing(entry)
            missingCache[entry.id] = missing
            if missing {
                showNotice(L("clipboard.notice.missingFile"))
                return
            }
        }
        onAction?(action, entry)
    }

    // MARK: - Number shortcuts

    /// The `⌘` number shown on the row at `index`: rows count from the first one fully on screen.
    func shortcutNumber(at index: Int) -> Int? {
        AskLauncherNumberShortcuts.number(at: index - firstVisibleIndex)
    }

    /// `⌘1`…`⌘9` paste the n-th row on screen.
    func quickPaste(number: Int) {
        let index = firstVisibleIndex + number - 1
        guard (1 ... 9).contains(number), visibleEntries.indices.contains(index) else { return }
        perform(.paste, at: index)
    }

    /// Records which row the list shows first; the view reports it as the list scrolls.
    func updateFirstVisibleIndex(_ index: Int) {
        let clamped = max(0, min(index, max(0, visibleEntries.count - 1)))
        if clamped != firstVisibleIndex { firstVisibleIndex = clamped }
    }

    /// The first row whose frame lies fully inside a viewport `height` points tall, given row
    /// frames in the viewport's coordinates. Rows partly scrolled out do not count; when no row
    /// fits completely (a very tall row), the first row reaching into the viewport is used.
    static func firstFullyVisibleIndex(frames: [Int: ClosedRange<CGFloat>], viewportHeight: CGFloat) -> Int? {
        let tolerance: CGFloat = 1
        let ordered = frames.sorted { $0.key < $1.key }
        if let full = ordered.first(where: {
            $0.value.lowerBound >= -tolerance && $0.value.upperBound <= viewportHeight + tolerance
        }) {
            return full.key
        }
        return ordered.first { $0.value.upperBound > 0 && $0.value.lowerBound < viewportHeight }?.key
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

    // MARK: - Private

    private func setEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
        searchIndex = Dictionary(
            entries.map { ($0.id, ClipboardFeed.searchableText(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func refilter(resetSelection: Bool) {
        let signpost = ClipboardPerformance.begin("refilter")
        defer { ClipboardPerformance.end("refilter", signpost) }
        visibleEntries = ClipboardFeed.filter(entries, category: category, query: query) { [searchIndex] entry in
            searchIndex[entry.id] ?? ClipboardFeed.searchableText(of: entry)
        }
        rows = Self.rows(for: visibleEntries, now: now())
        if resetSelection {
            firstVisibleIndex = 0
            scrollToTopRequest += 1
        } else {
            firstVisibleIndex = min(firstVisibleIndex, max(0, visibleEntries.count - 1))
        }
        selectedIndex = resetSelection ? 0 : clampedIndex(selectedIndex)
        refreshPreviewNow()
    }

    static func rows(for entries: [ClipboardEntry], now: Date) -> [Row] {
        var previous: ClipboardFeed.Section?
        return entries.enumerated().map { index, entry in
            let section = ClipboardFeed.section(for: entry, now: now)
            defer { previous = section }
            return Row(entry: entry, index: index, header: section == previous ? nil : section)
        }
    }

    private func schedulePreview() {
        previewWorkItem?.cancel()
        guard showsPreview else { return }
        guard previewDelay > 0 else {
            refreshPreviewNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.refreshPreviewNow() }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay, execute: work)
    }

    private func refreshPreviewNow() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        let next = showsPreview ? selectedEntry : nil
        if next != previewEntry { previewEntry = next }
    }

    private func clampedIndex(_ index: Int) -> Int {
        max(0, min(index, visibleEntries.count - 1))
    }
}
