import SwiftUI

/// The word list lives in the navigation sidebar; reading content stays solid.
struct AskWordBookView: View {
    @ObservedObject var model: AskWordBookViewModel
    var onClose: () -> Void
    @StateObject private var search = TypefluxSearchState()
    @State private var showsLookup = false
    @State private var regenerating: AskWordBookEntry?

    var body: some View {
        TypefluxWindow(title: L("ask.wordBook.title"), search: search, searchPrompt: L("ask.wordBook.search"),
                       groups: toolbarGroups, prominent: TypefluxToolbarAction(
                        id: "wordBook.new", title: L("ask.wordBook.firstLookup"), systemImage: "plus",
                        isEnabled: model.lookingUp == nil, perform: { showsLookup = true })) {
            AskWordBookList(model: model)
        } detail: {
            detailColumn
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AskWordBookFilterMenu(model: model) }
        }
        .onAppear { search.query = model.filterText }
        .onChange(of: search.query) { model.filterText = $0 }
        .onChange(of: model.filterText) { if search.query != $0 { search.query = $0 } }
        .sheet(isPresented: $showsLookup) { AskWordBookLookupView(model: model) }
        .background(shortcuts)
        .alert(L("ask.wordBook.regenerate.title"), isPresented: Binding(
            get: { regenerating != nil }, set: { if !$0 { regenerating = nil } }
        ), presenting: regenerating) { entry in
            Button(L("ask.wordBook.regenerate")) { Task { await model.regenerate(entry) } }
            Button(L("ask.workflow.cancel"), role: .cancel) {}
        } message: { entry in
            Text(L("ask.wordBook.regenerate.message", entry.headword, model.modelName()))
        }
        .accessibilityIdentifier("ask.wordBook")
    }

    @ViewBuilder private var detailColumn: some View {
        Group {
            if let word = model.lookingUp {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(word).font(.title2).textSelection(.enabled)
                    Text(L("ask.wordBook.lookup.writing", model.modelName())).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("ask.wordBook.loading")
            } else if let entry = model.displayed {
                AskWordBookDetail(model: model, entry: entry, regenerate: { regenerating = $0 })
            } else {
                TypefluxEmptyState(L((model.counts[.all] ?? 0) == 0
                    ? "ask.wordBook.emptyBook.title" : "ask.wordBook.choose"),
                    systemImage: "character.book.closed", description: L("ask.wordBook.emptyBook.detail"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { notice }
    }

    var toolbarGroups: [TypefluxToolbarGroup] {
        let entry = model.displayed
        let enabled = entry != nil && model.lookingUp == nil
        var actions = [
            TypefluxToolbarAction(id: "wordBook.star", title: L(entry?.isStarred == true
                ? "ask.wordBook.unstar" : "ask.wordBook.star"),
                systemImage: entry?.isStarred == true ? "star.fill" : "star", isEnabled: enabled,
                perform: { if let entry = toolbarEntry { model.toggleStar(entry) } }),
            TypefluxToolbarAction(id: "wordBook.copy", title: L("ask.plugin.action.copyDefinition"),
                systemImage: "doc.on.doc", isEnabled: enabled,
                perform: { if let entry = toolbarEntry { model.copyMeaning(entry) } }),
            TypefluxToolbarAction(id: "wordBook.speak", title: L("ask.plugin.action.speak"),
                systemImage: "speaker.wave.2", isEnabled: enabled,
                perform: { if let entry = toolbarEntry { model.speak(entry) } })
        ]
        if model.askAI != nil {
            actions.append(TypefluxToolbarAction(id: "wordBook.ask", title: L("ask.quick.askAI"),
                systemImage: "bubble.left", isEnabled: enabled,
                perform: { if let entry = toolbarEntry { model.ask(about: entry) } }))
        }
        if model.canRegenerate {
            actions.append(TypefluxToolbarAction(id: "wordBook.regenerate", title: L("ask.plugin.action.regenerate"),
                systemImage: "arrow.clockwise", isEnabled: enabled && model.regenerating == nil,
                perform: { if model.regenerating == nil { regenerating = toolbarEntry } }))
        }
        actions.append(TypefluxToolbarAction(id: "wordBook.delete", title: L(entry.map { model.isTransient($0) } == true
            ? "ask.wordBook.dismiss" : "ask.wordBook.delete"), systemImage: "trash", role: .destructive,
            isEnabled: enabled, perform: { if let entry = toolbarEntry { model.delete(entry) } }))
        return [TypefluxToolbarGroup(id: "wordBook.actions", actions: actions)]
    }

    /// Resolve at activation time; a native control can outlive the entry it was rendered for.
    private var toolbarEntry: AskWordBookEntry? { model.lookingUp == nil ? model.displayed : nil }

    @ViewBuilder private var notice: some View {
        if let notice = model.notice {
            HStack {
                Text(notice).font(.callout)
                if !model.deleted.isEmpty {
                    TypefluxButton(L("ask.wordBook.undo"), action: model.undoDelete)
                }
                TypefluxIconButton(L("ask.artifact.close"), systemImage: "xmark") { model.notice = nil }
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(TypefluxColor.contentBackground.color)
            .accessibilityIdentifier("ask.wordBook.notice")
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { showsLookup = true }.keyboardShortcut("l").disabled(model.lookingUp != nil)
            Button("") { showsLookup = true }.keyboardShortcut("n").disabled(model.lookingUp != nil)
            Button("") { if let entry = toolbarEntry { model.toggleStar(entry) } }.keyboardShortcut("s")
            Button("") { if let entry = toolbarEntry { model.copyMeaning(entry) } }
                .keyboardShortcut("c").disabled(search.isFocused || showsLookup)
            Button("") { if let entry = toolbarEntry { model.delete(entry) } }
                .keyboardShortcut(.delete, modifiers: []).disabled(search.isFocused || showsLookup)
            Button("") { model.undoDelete() }.keyboardShortcut("z")
                .disabled(model.deleted.isEmpty || search.isFocused || showsLookup)
            Button("") { if !search.escape() { onClose() } }.keyboardShortcut(.cancelAction)
        }
        .opacity(0).accessibilityHidden(true)
    }
}
