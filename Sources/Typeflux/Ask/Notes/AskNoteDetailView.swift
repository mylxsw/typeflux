import SwiftUI

// The solid reading column shows the selected note, editor or batch selection.
// Keep the reader, editor and their shared state in one view.
// swiftlint:disable:next type_body_length
struct AskNoteDetailView: View {
    @ObservedObject var model: AskNotesViewModel
    var focus: FocusState<AskNotesField?>.Binding
    @StateObject private var editor = AskMarkdownEditorController()
    @State private var titleDraft = ""
    @State private var titleNoteID: UUID?
    @State private var titleBaseline = ""
    @State private var tagDraft = ""
    @State private var showsOriginal = true
    @State private var jump: AskNoteJump?
    @State private var batchTag = ""
    @State private var showsBatchTag = false

    static let readingWidth = AskLibraryLayout.readingWidth
    static let outlineWidth: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { resetTitle() }
        .onChange(of: model.selectedID) { _ in
            commitTitle()
            resetTitle()
            tagDraft = ""
            jump = nil
        }
        .onDisappear { commitTitle() }
        .onChange(of: model.selected?.title) { title in
            if titleNoteID == model.selectedID, titleDraft == titleBaseline {
                titleDraft = title ?? ""
                titleBaseline = titleDraft
            }
        }
        .onChange(of: focus.wrappedValue) { field in if field != .title, model.selected != nil { commitTitle() } }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        if model.selecting {
            picking
        } else if let note = model.selected {
            VStack(spacing: 0) {
                switch model.mode {
                case .read: reading(note, width: width)
                case .edit: editing(note, width: width)
                case .split: splitting(note, width: width)
                }
            }
        } else {
            emptyState
        }
    }

    private func resetTitle() {
        titleNoteID = model.selectedID
        titleDraft = model.pendingTitle ?? model.selected?.title ?? ""
        titleBaseline = model.selected?.title ?? ""
    }

    private func commitTitle() {
        guard titleDraft != titleBaseline, let id = titleNoteID else { return }
        guard model.savePendingTitle() else { return }
        titleDraft = model.store.note(id: id)?.title ?? titleDraft
        titleBaseline = titleDraft
    }

    // MARK: - Header

    private func titleField(compact: Bool) -> some View {
        TextField(L("ask.notes.title.placeholder"), text: Binding(
            get: { titleDraft },
            set: { value in
                titleDraft = value
                if let id = titleNoteID { model.stageTitle(value, id: id) }
            }
        ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(compact ? .title2 : .title).fontWeight(.bold)
            .foregroundStyle(TypefluxColor.label.color)
            .lineLimit(1 ... 3)
            .focused(focus, equals: .title)
            .onSubmit { commitTitle(); focus.wrappedValue = nil }
            .disabled(model.selected?.isDeleted == true)
            .accessibilityIdentifier("ask.notes.title")
    }

    private func header(_ note: AskNote, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.editing {
                titleField(compact: compact)
            } else {
                Text(note.title.isEmpty ? L("ask.notes.untitled") : note.title)
                    .font(compact ? .title2 : .title).fontWeight(.bold)
                    .foregroundStyle(TypefluxColor.label.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("ask.notes.title")
            }
            if model.editing {
                Text(L(model.hasUnsavedDraft || model.pendingTitle != nil ? "ask.notes.saving" : "ask.notes.autosaved"))
                    .font(.caption).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            VStack(alignment: .leading, spacing: 7) {
                property("link", L("ask.notes.prop.source")) { sourceLine(note) }
                property("clock", L("ask.notes.prop.time")) { timeLine(note) }
                property("tag", L("ask.notes.prop.tags")) { tagLine(note) }
            }
            if !note.input.isEmpty, !compact || model.mode == .read { originCard(note) }
        }
    }

    private func property<Content: View>(_ symbol: String, _ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                .font(.callout).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .frame(width: 72, alignment: .leading)
            content().font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
        }
    }

    private func sourceLine(_ note: AskNote) -> some View {
        var chip = note.source.title
        if note.source == .command, !note.command.isEmpty {
            chip = note.command + (note.keyword.isEmpty ? "" : " · " + note.keyword)
        }
        var details: [String] = []
        if let model = note.model, !model.isEmpty { details.append(model) }
        if let app = note.sourceApp, !app.isEmpty { details.append(L("ask.notes.from", app)) }
        if note.author == .agent { details.append(L("ask.notes.byAgent")) }
        return HStack(spacing: 6) {
            Label(chip, systemImage: note.source.symbol).font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(TypefluxColor.accent.color)
            if !details.isEmpty { Text(details.joined(separator: " · ")).lineLimit(1).layoutPriority(-1) }
            if model.canOpenSource {
                Button(action: model.openSource) {
                    ViewThatFits(in: .horizontal) {
                        Label(L("ask.notes.openConversation"), systemImage: "arrow.uturn.backward")
                            .fixedSize()
                        Image(systemName: "arrow.uturn.backward").frame(width: 20, height: 21)
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain).foregroundStyle(TypefluxColor.accent.color)
                .help(L("ask.notes.openConversation"))
                .accessibilityLabel(L("ask.notes.openConversation"))
                .accessibilityIdentifier("ask.notes.openConversation")
            }
        }
    }

    private func timeLine(_ note: AskNote) -> some View {
        var parts = [L("ask.notes.created", note.createdAt.formatted(date: .abbreviated, time: .shortened))]
        if let edited = note.editedAt {
            parts.append(L("ask.notes.editedAt", edited.formatted(date: .abbreviated, time: .shortened)))
        }
        return HStack(spacing: 6) {
            Text(parts.joined(separator: " · ")).lineLimit(1)
            if model.agentRevision != nil, !note.isDeleted {
                Button(L("ask.notes.revertAgent"), action: model.revertAgentChange)
                    .buttonStyle(.plain).foregroundStyle(TypefluxColor.accent.color)
            }
        }
    }

    private func tagLine(_ note: AskNote) -> some View {
        AskWordBookFlow(spacing: 5) {
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    TypefluxTag(tag)
                    if !note.isDeleted {
                        Button { model.removeTag(tag) } label: {
                            Image(systemName: "xmark").font(.caption).fontWeight(.bold)
                        }
                        .buttonStyle(.plain).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .accessibilityLabel(L("ask.notes.tag.remove", tag))
                    }
                }

            }
            if !note.isDeleted {
                TextField(L("ask.notes.tag.add"), text: $tagDraft)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .frame(width: 96)
                    .focused(focus, equals: .tag)
                    .onSubmit { model.addTag(tagDraft); tagDraft = ""; focus.wrappedValue = .tag }
                    .accessibilityIdentifier("ask.notes.tag")
            }
        }
    }

    private func originCard(_ note: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsOriginal.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsOriginal ? "chevron.down" : "chevron.right")
                        .font(.caption).fontWeight(.semibold)
                    Text(L(note.source == .chat ? "ask.notes.question" : "ask.result.original")).font(.callout)
                    Spacer(minLength: 4)
                }
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsOriginal {
                ScrollView(.vertical) {
                    Text(note.input).font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 96)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(TypefluxColor.separator.color).frame(width: 2) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(TypefluxColor.controlBackground.color)
    }

    // MARK: - Reading

    private func reading(_ note: AskNote, width: CGFloat) -> some View {
        let showsOutline = model.showsOutline && note.headings.count >= 2 && width > 720
        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    header(note, compact: width < 520)
                    Rectangle().fill(TypefluxColor.separator.color).frame(height: 0.5)
                    if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { model.beginEditing() } label: {
                            Text(L("ask.notes.emptyBody")).font(.body)
                                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        }
                        .buttonStyle(.plain)
                    } else {
                        AskNoteReaderText(text: note.body,
                                          highlight: AskNotesViewModel.parseSearch(model.searchText).text,
                                          jump: jump, onToggleTask: note.isDeleted ? nil : { model.toggleTask($0) })
                            .id(note.id)
                    }
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, width < 520 ? 18 : 36).padding(.top, 6).padding(.bottom, 24)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !note.isDeleted { model.beginEditing() } }
            if showsOutline { outline(note).frame(width: Self.outlineWidth) }
        }
    }

    private func outline(_ note: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("ask.notes.outline")).font(.caption).fontWeight(.semibold)
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(note.headings.enumerated()), id: \.element.id) { index, heading in
                        Button { jump = AskNoteJump(heading: index) } label: {
                            Text(AskNote.plainText(heading.text)).font(.callout).lineLimit(1)
                                .foregroundStyle(jump?.heading == index
                                    ? TypefluxColor.label.color : TypefluxColor.secondaryLabel.color)
                                .padding(.leading, CGFloat(heading.level - 1) * 10 + 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(jump?.heading == index
                                            ? TypefluxColor.accent.color : TypefluxColor.separator.color)
                                        .frame(width: 2)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 360)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("ask.notes.stats.characters", note.characterCount))
                Text(L("ask.notes.stats.minutes", max(1, Int((Double(note.characterCount) / 400).rounded()))))
                let tasks = note.taskProgress
                if tasks.total > 0 { Text(L("ask.notes.stats.tasks", tasks.done, tasks.total)) }
            }
            .font(.caption).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.top, 8).padding(.trailing, 18)
        .accessibilityIdentifier("ask.notes.outline")
    }

    // MARK: - Editing

    private func editing(_ note: AskNote, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(note, compact: true)
            formatBar
            AskMarkdownEditor(text: $model.draftBody, controller: editor)
                .id(note.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: Self.readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, width < 520 ? 18 : 36).padding(.top, 6).padding(.bottom, 16)
    }

    private func splitting(_ note: AskNote, width: CGFloat) -> some View {
        let stacked = width < 600
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            VStack(alignment: .leading, spacing: 12) {
                titleField(compact: true)
                formatBar
                AskMarkdownEditor(text: $model.draftBody, controller: editor)
                    .id(note.id)
            }
            .padding(.horizontal, stacked ? 18 : 24).padding(.top, 6).padding(.bottom, 12)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            Rectangle().fill(TypefluxColor.separator.color)
                .frame(width: stacked ? nil : 0.5, height: stacked ? 0.5 : nil)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("ask.notes.preview")).font(.caption).fontWeight(.semibold)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    AskNoteReaderText(text: model.draftBody)
                        .accessibilityIdentifier("ask.notes.splitPreview")
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, stacked ? 18 : 24).padding(.top, 8).padding(.bottom, 24)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var formatBar: some View {
        ViewThatFits(in: .horizontal) {
            formatButtons
            ScrollView(.horizontal, showsIndicators: true) {
                formatButtons
            }
            // Leave room for a legacy horizontal scrollbar as well as overlay scrollbars.
            .frame(height: 52)
            .accessibilityIdentifier("ask.notes.formatScroll")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.notes.formatBar")
    }

    private var formatButtons: some View {
        HStack(spacing: 1) {
            Menu {
                Button(L("ask.notes.format.heading1") + "  ⌘1") { editor.apply(.heading1) }
                Button(L("ask.notes.format.heading2") + "  ⌘2") { editor.apply(.heading2) }
                Button(L("ask.notes.format.heading3") + "  ⌘3") { editor.apply(.heading3) }
            } label: {
                Text(verbatim: "H").font(.body).fontWeight(.bold)
            }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 34)
            .help(L("ask.notes.format.heading"))
            divider
            formatButton(.bold, symbol: "bold", key: "⌘B")
            formatButton(.italic, symbol: "italic", key: "⌘I")
            formatButton(.strikethrough, symbol: "strikethrough", key: "⇧⌘X")
            divider
            formatButton(.bulletList, symbol: "list.bullet", key: nil)
            formatButton(.taskList, symbol: "checklist", key: "⇧⌘L")
            formatButton(.quote, symbol: "text.quote", key: nil)
            formatButton(.code, symbol: "chevron.left.forwardslash.chevron.right", key: nil)
            formatButton(.link, symbol: "link", key: "⌘K")
            formatButton(.table, symbol: "tablecells", key: nil)
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(TypefluxColor.contentBackground.color)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(TypefluxColor.separator.color).frame(width: 0.5, height: 16).padding(.horizontal, 3)
    }

    private func formatButton(_ format: AskMarkdownFormat, symbol: String, key: String?) -> some View {
        let title = L("ask.notes.format." + "\(format)")
        return TypefluxIconButton(title + (key.map { " " + $0 } ?? ""), systemImage: symbol) {
            editor.apply(format)
        }
    }

    // MARK: - Picking and empty

    private var picking: some View {
        let chosen = model.pickedNotes
        return VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(TypefluxColor.accent.color)

            Text(L("ask.notes.picked", chosen.count)).font(.title3).fontWeight(.semibold)
            Text(chosen.prefix(6).map(\.title).joined(separator: "、") + (chosen.count > 6 ? "…" : ""))
                .font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Text(L("ask.notes.pickHint")).font(.caption).foregroundStyle(TypefluxColor.tertiaryLabel.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            batchActions.disabled(chosen.isEmpty).padding(12)
                .background(TypefluxColor.contentBackground.color)
                .accessibilityIdentifier("ask.notes.batchBar")
        }
    }

    private var batchActions: some View {
        HStack(spacing: 8) {
            TypefluxIconButton(L("ask.notes.batch.tag"), systemImage: "tag") { showsBatchTag = true }
                .popover(isPresented: $showsBatchTag) {
                    TextField(L("ask.notes.tag.add"), text: $batchTag)
                        .textFieldStyle(.roundedBorder).frame(width: 160).padding(12)
                        .onSubmit { model.tagPicked(batchTag); batchTag = ""; showsBatchTag = false }
                }
            TypefluxIconButton(L("ask.notes.pin"), systemImage: "pin", action: model.pinPicked)
            TypefluxIconButton(L("ask.notes.batch.copy"), systemImage: "doc.on.doc", action: model.copyPicked)
            TypefluxIconButton(L("ask.notes.batch.export"), systemImage: "square.and.arrow.up",
                               action: model.exportPicked)
            TypefluxIconButton(L("ask.notes.delete"), systemImage: "trash", kind: .destructive,
                               action: model.trashPicked)
        }
    }

    private var emptyState: some View {
        TypefluxEmptyState(L(model.inTrash ? "ask.notes.trash.none" : "ask.notes.emptyTitle"),
                           systemImage: model.inTrash ? "trash" : "note.text",
                           description: model.inTrash ? ""
                            : L("ask.notes.emptySubtitle") + "\n" + L("ask.notes.empty")) {
            if !model.searchText.isEmpty, !model.inTrash {
                TypefluxButton(L("ask.notes.newTitled", AskNotesViewModel.parseSearch(model.searchText).text)) {
                    model.createNote(title: AskNotesViewModel.parseSearch(model.searchText).text)
                }
            }
        }
        .accessibilityIdentifier("ask.notes.emptyState")
    }
}
