import SwiftUI
import UniformTypeIdentifiers

typealias AskNotesLayout = AskLibraryLayout

/// The notes window, drawn like the conversation window and following the interface
/// style: shelves in the side panel, the list, and the chosen note to read or edit
/// (`docs/design/notebook-redesign.md`).
struct AskNotesView: View {
    @ObservedObject var model: AskNotesViewModel
    var onClose: () -> Void
    @FocusState private var focus: AskNotesField?
    @State private var dropTargeted = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    static let sidebarWidth = AskLibraryLayout.sidebarWidth
    static let listWidth = AskLibraryLayout.maximumListWidth

    var body: some View {
        GeometryReader { geometry in
            let layout = AskNotesLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.sidebarInline {
                    AskNotesSidebar(model: model)
                        .askSidePanel(edge: .leading)
                        .frame(width: layout.sidebarWidth, height: geometry.size.height)
                        .clipped()
                }
                AskNotesList(model: model, focus: $focus, sidebarCollapsed: !layout.sidebarInline)
                    .frame(width: layout.listWidth, height: geometry.size.height)
                    .clipped()
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(AskTheme.librarySeparator).frame(width: colorScheme == .light ? 1 : 0.5)
                    }
                AskNoteDetailView(model: model, focus: $focus)
                    .frame(width: layout.detailWidth, height: geometry.size.height)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // One surface for the whole window, as in the conversation window.
        .background(AskWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { noticeBar }
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Self.loadURLs(providers) { urls in model.importFiles(urls.filter(AskNoteImporter.canImport)) }
            return true
        }
        .background(shortcuts)
        .tint(AskTheme.accent)
        .accessibilityIdentifier("ask.notes")
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
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(AskTheme.accent.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(AskTheme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 26))
                    Text(L("ask.notes.dropTitle")).font(.system(size: 15, weight: .semibold))
                    Text(L("ask.notes.dropSubtitle")).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var noticeBar: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                if model.draftConflict {
                    Button(L("ask.notes.saveCopy")) { model.saveDraftCopy() }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AskTheme.accent)
                }
                if model.noticeOffersUndo, !model.deleted.isEmpty {
                    Button(L("ask.notes.undo")) { model.undoDelete() }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AskTheme.accent)
                }
                if model.noticeReveals != nil {
                    Button(L("ask.notes.showInFinder")) { model.revealNoticeTarget() }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AskTheme.accent)
                }
                Button { model.notice = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                .accessibilityLabel(L("ask.artifact.close"))
            }
            .padding(.horizontal, 14).frame(height: 34)
            .askInWindowGlass(corner: style.usesGlass ? 17 : 8, opaqueFill: AskTheme.glassFill, elevation: .popover)
            .padding(.bottom, 66)
            .transition(.opacity)
            .accessibilityIdentifier("ask.notes.notice")
        }
    }

    /// Keys for the list and the chosen note; typing in a field or the editor keeps its own keys.
    private var shortcuts: some View {
        let typing = focus != nil || model.editing
        return ZStack {
            Button("") { model.createNote() }.keyboardShortcut("n")
            Button("") { focus = .search }.keyboardShortcut("f")
            Button("") { model.toggleEditing() }.keyboardShortcut("e")
            Button("") { model.setMode(model.mode == .split ? .read : .split) }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("") { model.exportSelected(.markdown) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("") { model.togglePin() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { model.moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: []).disabled(typing)
            Button("") { model.moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: []).disabled(typing)
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
        if model.editing {
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
