import SwiftUI

/// Interactive examples plus persistent empty, disabled and filtering states.
public struct TypefluxNavigationGallery: View {
    @StateObject private var search = TypefluxSearchState()
    @StateObject private var expandedSearch = TypefluxSearchState(expanded: true)
    @StateObject private var filteringSearch: TypefluxSearchState
    @StateObject private var disabledSearch = TypefluxSearchState()
    @StateObject private var hud = TypefluxHUDState()
    @State private var inlineQuery = ""
    @State private var panelQuery = ""
    @State private var mode = ""
    @State private var selection: String?
    @State private var showWindow = false
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var showDialog = false
    private let labels: TypefluxNavigationGalleryLabels
    private let items: [TypefluxSpotlightItem]
    private let modes: [TypefluxSpotlightMode]

    public init(labels: TypefluxNavigationGalleryLabels, items: [TypefluxSpotlightItem],
                modes: [TypefluxSpotlightMode]) {
        self.labels = labels
        _filteringSearch = StateObject(wrappedValue: TypefluxSearchState(query: labels.sampleQuery))
        self.items = items
        self.modes = modes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(labels.navigation).font(.title2)
            HStack {
                TypefluxButton(labels.window) { showWindow = true }
                TypefluxButton(labels.sheet) { showSheet = true }
                TypefluxButton(labels.alert) { showAlert = true }
                TypefluxButton(labels.dialog) { showDialog = true }
                TypefluxButton(labels.hud) { hud.present(TypefluxHUDMessage(title: labels.copied)) }
            }
            searchStates
            TypefluxGlassContainer {
                VStack(alignment: .leading, spacing: 8) {
                    Text(labels.inlineSearch).font(.headline)
                    TypefluxInlineSearch(text: $inlineQuery, prompt: labels.search)
                    TypefluxInlineSearch(text: .constant(labels.sampleQuery), prompt: labels.disabled).disabled(true)
                }.padding(16)
            }.frame(maxWidth: 320)
            Text(labels.panel).font(.headline)
            TypefluxSpotlightPanel(query: $panelQuery, mode: $mode, prompt: labels.search,
                                   items: filteredItems, modes: modes, emptyText: labels.empty, hints: labels.hints,
                                   activate: { _, _ in hud.present(TypefluxHUDMessage(title: labels.copied)) },
                                   dismiss: { panelQuery = "" })
                .frame(height: 240)
            TypefluxSpotlightPanel(query: .constant(""), mode: .constant(""), prompt: labels.search,
                                   items: [], emptyText: labels.empty, hints: labels.hints, autofocus: false,
                                   activate: { _, _ in }, dismiss: {})
                .frame(height: 190)
            HStack(alignment: .top, spacing: 20) {
                TypefluxHUD(message: TypefluxHUDMessage(title: labels.copied))
                TypefluxSheet(title: labels.sheet, cancelTitle: labels.cancel, confirmTitle: labels.confirm,
                              cancel: {}, confirm: {}, content: {
                                  TypefluxInlineSearch(text: .constant(labels.sampleQuery), prompt: labels.search)
                              }).frame(maxWidth: 420)
                TypefluxSheet(title: labels.disabled, cancelTitle: labels.cancel, confirmTitle: labels.confirm,
                              isConfirmEnabled: false, cancel: {}, confirm: {}, content: {
                                  TypefluxInlineSearch(text: .constant(""), prompt: labels.search)
                              }).frame(maxWidth: 420)
            }
        }
        .onAppear { mode = modes.first?.id ?? "" }
        .typefluxHUD(hud)
        .typefluxSheet(isPresented: $showSheet,
                       configuration: TypefluxSheetConfiguration(title: labels.sheet, cancelTitle: labels.cancel,
                                                                 confirmTitle: labels.confirm),
                       confirm: { true }, content: {
                           TypefluxInlineSearch(text: $inlineQuery, prompt: labels.search).frame(width: 320)
                       })
        .typefluxAlert(confirmation, isPresented: $showAlert) { hud.present(TypefluxHUDMessage(title: labels.copied)) }
        .typefluxConfirmationDialog(confirmation, isPresented: $showDialog) {}
        .sheet(isPresented: $showWindow) {
            VStack(spacing: 0) {
                windowExample
                HStack {
                    Spacer()
                    Button(labels.cancel) { showWindow = false }.keyboardShortcut(.cancelAction)
                }.padding(12)
            }.frame(width: 850, height: 500)
        }
    }

    private var confirmation: TypefluxConfirmation {
        TypefluxConfirmation(title: labels.alert, message: labels.filtering, confirmTitle: labels.delete,
                             cancelTitle: labels.cancel, role: .destructive)
    }

    private var filteredItems: [TypefluxSpotlightItem] {
        panelQuery.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(panelQuery) }
    }

    private var searchStates: some View {
        HStack(alignment: .top, spacing: 24) {
            searchExample(labels.collapsed, state: search)
            searchExample(labels.expanded, state: expandedSearch)
            searchExample(labels.filtering, state: filteringSearch)
            searchExample(labels.disabled, state: disabledSearch).disabled(true)
        }
    }

    private func searchExample(_ title: String, state: TypefluxSearchState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout)
            TypefluxToolbarSearch(state: state, prompt: labels.search)
        }
    }

    private var windowExample: some View {
        TypefluxWindow(title: labels.window,
                       items: items.map { TypefluxNavigationItem(id: $0.id, title: $0.title,
                                                                 systemImage: $0.systemImage, count: 12) },
                       selection: $selection, search: search, searchPrompt: labels.search,
                       groups: [TypefluxToolbarGroup(id: "actions", actions: [
                           TypefluxToolbarAction(
                               id: "share",
                               title: labels.confirm,
                               systemImage: "square.and.arrow.up"
                           ) {},
                           TypefluxToolbarAction(id: "disabled", title: labels.disabled,
                                                 systemImage: "trash", isEnabled: false) {}
                       ])],
                       prominent: TypefluxToolbarAction(id: "new", title: labels.confirm, systemImage: "plus") {}) {
            Text(selection ?? labels.empty).padding()
        }
    }
}
