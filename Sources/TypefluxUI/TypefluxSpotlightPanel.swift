import AppKit
import SwiftUI

/// Spotlight layout and keyboard routing, independent of clipboard/launcher business logic.
public struct TypefluxSpotlightPanel: View {
    @Binding private var query: String
    @Binding private var mode: String
    @Environment(\.interfaceStyle) private var style
    @State private var focused: Bool
    @State private var selection = TypefluxSpotlightSelection()
    private let prompt: String
    private let items: [TypefluxSpotlightItem]
    private let modes: [TypefluxSpotlightMode]
    private let emptyText: String
    private let hints: [String]
    private let activate: (String, Bool) -> Void
    private let dismiss: () -> Void

    public init(query: Binding<String>, mode: Binding<String>, prompt: String,
                items: [TypefluxSpotlightItem], modes: [TypefluxSpotlightMode] = [],
                emptyText: String, hints: [String], autofocus: Bool = true,
                activate: @escaping (String, Bool) -> Void, dismiss: @escaping () -> Void) {
        _query = query
        _mode = mode
        _focused = State(initialValue: autofocus)
        self.prompt = prompt
        self.items = items
        self.modes = modes
        self.emptyText = emptyText
        self.hints = hints
        self.activate = activate
        self.dismiss = dismiss
    }

    public var body: some View {
        panel
            .onAppear { selection.reconcile(items) }
            .onChange(of: items) { selection.reconcile($0) }
            .background(TypefluxKeyboardMonitor { event in
                guard focused,
                      (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      let key = TypefluxSpotlightKey.resolve(keyCode: event.keyCode,
                                                             characters: event.charactersIgnoringModifiers,
                                                             modifiers: event.modifierFlags) else { return false }
                handle(key)
                return true
            }.frame(width: 0, height: 0))
            .accessibilityIdentifier("typeflux.spotlight")
    }

    @ViewBuilder private var panel: some View {
        if style == .classic {
            TypefluxGlassContainer(radius: .spotlightResults) {
                VStack(spacing: 0) {
                    inputRow
                    Divider()
                    results
                }
            }
        } else {
            TypefluxGlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TypefluxGlassContainer(radius: .spotlightInput) { input }
                        modeButtons
                    }
                    TypefluxGlassContainer(radius: .spotlightResults) { results }
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) { input; modeButtons }.padding(.trailing, 10)
    }

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(TypefluxColor.secondaryLabel.color)
                .accessibilityHidden(true)
            TypefluxNativeSearchField(text: $query, focused: $focused, prompt: prompt,
                                      identifier: "typeflux.spotlight.search", borderless: true, onEscape: dismiss)
        }
        .padding(.horizontal, 16)
        .frame(height: TypefluxControlHeight.spotlightInput.value(for: style))
    }

    private var modeButtons: some View {
        HStack(spacing: style == .classic ? 2 : 8) {
            ForEach(modes) { item in
                modeButton(item)
            }
        }
    }

    @ViewBuilder private func modeButton(_ item: TypefluxSpotlightMode) -> some View {
        let button = Button {
            mode = item.id
            focused = true
        } label: {
            Label(item.title, systemImage: item.systemImage).labelStyle(.iconOnly)
                .frame(width: style == .classic ? 30 : TypefluxControlHeight.spotlightModeButton.value(for: style),
                       height: style == .classic ? 26 : TypefluxControlHeight.spotlightModeButton.value(for: style))
        }
        .buttonStyle(.borderless)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(mode == item.id ? .isSelected : [])
        .accessibilityIdentifier("typeflux.spotlight.mode." + item.id)
        .foregroundStyle(mode == item.id ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
        if style == .classic {
            button
        } else {
            TypefluxGlassContainer(radius: .spotlightInput) { button }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text(emptyText).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                resultRow(item, number: index + 1).id(item.id)
                            }
                        }.padding(8)
                    }.frame(maxHeight: 320)
                        .onChange(of: selection.selectedID) { id in
                            if let id {
                                proxy.scrollTo(id)
                            }
                        }
                }
            }
            Divider()
            HStack(spacing: 16) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in Text(hint) }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func resultRow(_ item: TypefluxSpotlightItem, number: Int) -> some View {
        Button {
            selection.select(item.id, in: items)
            focused = true
            activate(item.id, false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(selection.selectedID == item.id ? selectedText : TypefluxColor.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.callout)
                            .foregroundStyle(selection.selectedID == item.id ? selectedText : TypefluxColor
                                .secondaryLabel.color)
                    }
                }
                Spacer()
                if number <= 9 {
                    Text("⌘\(number)").font(.footnote)
                        .foregroundStyle(selection.selectedID == item.id ? selectedText : TypefluxColor.secondaryLabel
                            .color)
                }
            }
            .foregroundStyle(selection.selectedID == item.id ? selectedText : TypefluxColor.label.color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: style == .classic ? 34 : 40, alignment: .leading)
            .background(selection.selectedID == item.id ? TypefluxColor.selection.color : .clear,
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection.selectedID == item.id ? .isSelected : [])
        .accessibilityIdentifier("typeflux.spotlight.result." + item.id)
    }

    private var selectedText: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }

    private func handle(_ key: TypefluxSpotlightKey) {
        switch key {
        case let .move(delta): selection.move(delta, in: items)
        case let .activate(plainText):
            if let id = selection.selectedID, items.contains(where: { $0.id == id && $0.isEnabled }) {
                activate(id, plainText)
            }
        case let .quick(number):
            if let item = selection.quickResult(number, in: items) {
                selection.select(item.id, in: items)
                activate(item.id, false)
            }
        case .dismiss: dismiss()
        }
    }
}
