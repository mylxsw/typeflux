import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native library window with a note list sidebar and a solid reading column.
struct AskNotesView: View {
    @ObservedObject var model: AskNotesViewModel
    var onClose: () -> Void
    @FocusState private var focus: AskNotesField?
    @State private var dropTargeted = false
    @StateObject private var search = TypefluxSearchState()
    static let expandedToolbarMinimumWidth: CGFloat = 1200

    var body: some View {
        GeometryReader { geometry in
            libraryWindow(compact: geometry.size.width < Self.expandedToolbarMinimumWidth || search.isExpanded)
        }
        .onAppear { search.query = model.searchText }
        .onChange(of: search.query) { query in
            model.searchText = query
            // Saving a failed draft can reject a filter change. Keep the native field truthful.
            if search.query != model.searchText { search.query = model.searchText }
        }
        .onChange(of: model.searchText) { query in
            if search.query != query { search.query = query }
        }
        .overlay(alignment: .bottom) { noticeBar }
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Self.loadURLs(providers) { urls in model.importFiles(urls.filter(AskNoteImporter.canImport)) }
            return true
        }
        .background(shortcuts)
        .tint(TypefluxColor.accent.color)
        .accessibilityIdentifier("ask.notes")
    }

    /// Keep the direct copy action reachable while secondary actions collapse into a native menu.
    private func libraryWindow(compact: Bool) -> some View {
        TypefluxWindow(title: L("ask.notes.title"), search: search, searchPrompt: L("ask.notes.search"),
                       groups: compact ? [] : toolbarGroups, prominent: TypefluxToolbarAction(
                        id: "notes.new", title: L("ask.notes.new"), systemImage: "square.and.pencil",
                        perform: { model.createNote() })) {
            AskNotesList(model: model)
        } detail: {
            AskNoteDetailView(model: model, focus: $focus)
        }
        .toolbar { libraryToolbar(compact: compact) }
    }

    /// Reads the dropped files' URLs, then hands them over on the main actor.
    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            let found = urls
            lock.unlock()
            MainActor.assumeIsolated { completion(found) }
        }
    }

    private var dropOverlay: some View {
        Rectangle()
            .fill(TypefluxColor.accent.color.opacity(0.10))
            .overlay(Rectangle()
                .strokeBorder(TypefluxColor.accent.color.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.largeTitle)
                    Text(L("ask.notes.dropTitle")).font(.headline)
                    Text(L("ask.notes.dropSubtitle")).font(.callout)
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var noticeBar: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice).font(.callout).foregroundStyle(TypefluxColor.label.color).lineLimit(1)
                if model.draftConflict {
                    Button(L("ask.notes.saveCopy")) { model.saveDraftCopy() }
                        .buttonStyle(.plain).font(.callout).fontWeight(.semibold)
                        .foregroundStyle(TypefluxColor.accent.color)
                }
                if model.noticeOffersUndo, !model.deleted.isEmpty {
                    Button(L("ask.notes.undo")) { model.undoDelete() }
                        .buttonStyle(.plain).font(.callout).fontWeight(.semibold)
                        .foregroundStyle(TypefluxColor.accent.color)
                }
                if model.noticeReveals != nil {
                    Button(L("ask.notes.showInFinder")) { model.revealNoticeTarget() }
                        .buttonStyle(.plain).font(.callout).fontWeight(.semibold)
                        .foregroundStyle(TypefluxColor.accent.color)
                }
                Button { model.notice = nil } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .accessibilityLabel(L("ask.artifact.close"))
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(TypefluxColor.contentBackground.color)
            .padding(.bottom, 12)
            .transition(.opacity)
            .accessibilityIdentifier("ask.notes.notice")
        }
    }

    /// Keys for the list and the chosen note; typing in a field or the editor keeps its own keys.
    private var shortcuts: some View {
        let typing = focus != nil || model.editing || search.isFocused
        return ZStack {
            Button("") { model.createNote() }.keyboardShortcut("n")
            Button("") { model.exportSelected(.markdown) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("") { model.togglePin() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { model.copySelectedRich() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(typing)
            Button("") { model.openSelectedInWindow() }.keyboardShortcut("o")
            Button("") { model.selecting ? model.trashPicked() : model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command).disabled(typing)
            Button("") { model.undoDelete() }.keyboardShortcut("z").disabled(model.deleted.isEmpty || typing)
            // Only while picking: otherwise ⌘A selects the text being read.
            Button("") { model.pickAll() }.keyboardShortcut("a").disabled(typing || !model.selecting)
            Button("") { onClose() }.keyboardShortcut("w")
            Button("") { escape() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func escape() {
        if search.escape() {
            return
        } else if model.editing {
            model.setMode(.read)
        } else if focus != nil {
            focus = nil
        } else if model.selecting {
            model.setSelecting(false)
        } else if !model.searchText.isEmpty {
            model.searchText = ""
        } else {
            onClose()
        }
    }
}
