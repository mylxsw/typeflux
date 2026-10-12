import Foundation

extension ClipboardPanelModel {
    func cancelSnippetEdit() {
        snippetDraft = nil
        snippetError = nil
    }

    func commitSnippet() {
        guard let draft = snippetDraft else { return }
        do {
            _ = try ClipboardSnippet.validated(name: draft.name, text: draft.text, alias: draft.alias)
            guard let onSaveSnippet else { throw ClipboardSnippetError.unavailable }
            let saved = try onSaveSnippet(draft)
            cancelSnippetEdit()
            setAppFilter(nil)
            query = ""
            category = .snippet
            let entry = ClipboardFeed.entry(for: saved)
            replaceEntries([entry] + entries.filter { $0.id != entry.id })
            select(index: 0)
            showNotice(L("clipboard.snippet.saved"))
        } catch {
            snippetError = (error as? ClipboardSnippetError)?.errorDescription
                ?? L("clipboard.snippet.error.unavailable")
        }
    }
}
