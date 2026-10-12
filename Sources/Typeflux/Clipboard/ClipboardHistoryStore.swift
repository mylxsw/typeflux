import Foundation

extension Notification.Name {
    static let clipboardHistoryDidChange = Notification.Name("ClipboardHistoryStore.didChange")
}

/// Persists clipboard history captured by `ClipboardMonitor`.
///
/// Snippets and pinned items are exempt from `purge` and `trim`. Voice history records live in
/// `HistoryStore`; only their pin state is kept here.
protocol ClipboardHistoryStore: AnyObject {
    /// Stores a capture, or moves an identical existing item to the top.
    @discardableResult
    func record(_ capture: ClipboardCapture, source: ClipboardSource?, at date: Date) -> ClipboardItem?
    func items(limit: Int) -> [ClipboardItem]
    /// Updates an existing text item, or creates a text snapshot (e.g. of a voice result).
    /// Throws on validation or persistence failure; successful saves are never pinned.
    func saveSnippet(id: UUID?, name: String, text: String, alias: String,
                     source: ClipboardSource?, at date: Date) throws -> ClipboardItem
    func setPinned(_ pinned: Bool, id: UUID)
    func delete(id: UUID)
    /// Removes non-snippet, unpinned items copied before `cutoff`.
    func purge(olderThan cutoff: Date)
    /// Keeps at most `maxCount` non-snippet, unpinned items, removing the oldest first. Implementations may
    /// keep fewer unpinned images to bound disk use.
    func trim(toMaxCount maxCount: Int)
    /// Deletes non-snippet, unpinned items, all of them or only those copied from one app.
    func deleteUnpinned(sourceBundleID: String?)
    /// Removes the oldest unpinned images until the stored images take at most `maxBytes`.
    func trim(toMaxImageBytes maxBytes: Int64)
    func pinnedVoiceRecordIDs() -> Set<UUID>
    func setVoiceRecordPinned(_ pinned: Bool, recordID: UUID)
}
