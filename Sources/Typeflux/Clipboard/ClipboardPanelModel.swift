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
    /// Only entries copied from this app are shown.
    @Published private(set) var appFilter: ClipboardAppFilter?
    /// Text being edited before pasting (`⌘E`); `nil` when not editing.
    @Published var editingText: String?
    @Published private(set) var pendingConfirmation: ClipboardPanelConfirmation?
    /// Mirrors the recording pause, shown in the footer.
    @Published var isRecordingPaused = false
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
    var onCommand: ((ClipboardPanelCommand) -> Void)?
    var onDismiss: (() -> Void)?
    var onPreviewVisibilityChange: ((Bool) -> Void)?
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var now: () -> Date = Date.init
    var previewDelay: TimeInterval = 0.12
    /// A single click pastes the row instead of selecting it.
    var singleClickPastes = false

    private var noticeGeneration = 0
    private var previewWorkItem: DispatchWorkItem?
    /// Whether an entry's files are gone, checked once per entry per session instead of on every redraw.
    private var missingCache: [String: Bool] = [:]
    /// Lowercase-insensitive search text per entry ID, built once per entry list.
    private var searchIndex: [String: String] = [:]

    var selectedEntry: ClipboardEntry? {
        visibleEntries.indices.contains(selectedIndex) ? visibleEntries[selectedIndex] : nil
    }

    /// Starts a new session: all entries, no search, first row selected — or, with
    /// `selectFirstUnpinned`, the newest row below the pinned ones.
    func reset(entries: [ClipboardEntry], selectFirstUnpinned: Bool = false) {
        missingCache = [:]
        setEntries(entries)
        notice = nil
        editingText = nil
        pendingConfirmation = nil
        appFilter = nil
        query = ""
        category = .all
        refilter(resetSelection: true)
        if selectFirstUnpinned, let index = visibleEntries.firstIndex(where: { !$0.isPinned }) {
            selectedIndex = index
            refreshPreviewNow()
        }
    }

    /// A click on a row: selects it, or pastes it when single clicks paste.
    func click(index: Int) {
        if singleClickPastes {
            perform(.paste, at: index)
        } else {
            select(index: index)
        }
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

    /// Runs an action on the entry at `index`, or on the selected entry. Panel-side actions
    /// (editing, filtering by app, deleting an app's items) are handled here.
    func perform(_ action: ClipboardEntryAction, at index: Int? = nil) {
        if let index { select(index: index) }
        guard let entry = selectedEntry, actions(for: entry).contains(action) else { return }
        switch action {
        case .editBeforePaste:
            editingText = entry.text
            return
        case .showOnlyApp:
            setAppFilter(ClipboardAppFilter(entry: entry))
            return
        case .deleteAllFromApp:
            if let app = ClipboardAppFilter(entry: entry) {
                let count = entries.filter { $0.sourceBundleID == app.bundleID && !$0.isPinned }.count
                pendingConfirmation = .deleteApp(app, count: count)
            }
            return
        default:
            break
        }
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
        visibleEntries = ClipboardFeed.filter(
            entries, category: category, query: query, sourceBundleID: appFilter?.bundleID
        ) { [searchIndex] entry in
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

// MARK: - Panel commands

extension ClipboardPanelModel {
    func setAppFilter(_ filter: ClipboardAppFilter?) {
        guard filter != appFilter else { return }
        appFilter = filter
        refilter(resetSelection: true)
    }

    /// Pastes the edited text and leaves editing; empty text is not pasted.
    func commitEdit() {
        guard let text = editingText else { return }
        editingText = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCommand?(.pasteText(text))
    }

    func cancelEdit() {
        editingText = nil
    }

    /// Asks to delete every unpinned clipboard item; voice results stay.
    func requestClearUnpinned() {
        let count = entries.filter { !$0.isPinned && $0.kind != .voice }.count
        guard count > 0 else {
            showNotice(L("clipboard.notice.nothingToClear"))
            return
        }
        pendingConfirmation = .clearUnpinned(count: count)
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        onCommand?(pending.command)
    }

    func cancelPending() {
        pendingConfirmation = nil
    }

    func send(_ command: ClipboardPanelCommand) {
        onCommand?(command)
    }

    /// Escape backs out one step: a confirmation, the editor, the search, the app filter, then
    /// the panel itself.
    func cancel() {
        if pendingConfirmation != nil {
            pendingConfirmation = nil
        } else if editingText != nil {
            editingText = nil
        } else if !query.isEmpty {
            query = ""
        } else if appFilter != nil {
            setAppFilter(nil)
        } else {
            onDismiss?()
        }
    }
}
