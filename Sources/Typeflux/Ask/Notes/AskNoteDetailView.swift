import SwiftUI

// swiftlint:disable file_length

// The right column: the chosen note to read or edit, the picked notes, or what to do
// with a note in Recently Deleted.
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
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

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
                topBar(note, compact: width < 520)
                switch model.mode {
                case .read: reading(note, width: width)
                case .edit: editing(note, width: width)
                case .split: splitting(note, width: width)
                }
            }
            .overlay(alignment: .bottom) { actionBar(note, width: width) }
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
        let submitted = titleDraft
        model.perform {
            guard await model.savePendingTitle(), titleNoteID == id, titleDraft == submitted else { return }
            titleDraft = model.notes.first(where: { $0.id == id })?.title ?? submitted
            titleBaseline = titleDraft
        }
    }

    // MARK: - Top bar

    private func topBar(_ note: AskNote, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if note.isDeleted {
                trashControls
            } else {
                sourceCrumb(note, compact: compact)
                if note.pinned, !compact {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(StudioTheme.textTertiary)
                }
                Spacer(minLength: 8)
                if model.editing {
                    saveStatus(compact: compact)
                }
                modePicker
                    .padding(.trailing, 2)
                AskIconGhostButton(label: L(note.pinned ? "ask.notes.unpin" : "ask.notes.pin") + " ⇧⌘P",
                                   systemImage: note.pinned ? "pin.fill" : "pin", action: { model.perform { await model.togglePin() } })
                if !note.headings.isEmpty {
                    AskIconGhostButton(label: L("ask.notes.outline"), systemImage: "list.bullet.indent") {
                        if model.editing {
                            model.perform { await model.setMode(.read) }
                            model.showsOutline = true
                        } else {
                            model.showsOutline.toggle()
                        }
                    }
                }
                exportMenu(note)
                moreMenu()
            }
        }
        .padding(.leading, 22).padding(.trailing, 12)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private func sourceCrumb(_ note: AskNote, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: note.source.symbol).font(.system(size: 11))
                .foregroundStyle(AskNotesStyle.sourceColor(note.source))
            if !compact {
                Text(crumb(note)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
            }
        }
        .help(crumb(note))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crumb(note))
    }

    private func saveStatus(compact: Bool) -> some View {
        let saving = model.hasUnsavedDraft || model.pendingTitle != nil
        let label = L(saving ? "ask.notes.saving" : "ask.notes.autosaved")
        return HStack(spacing: 5) {
            Circle().fill(saving ? StudioTheme.warning : StudioTheme.success).frame(width: 6, height: 6)
            if !compact { Text(label).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary) }
        }
        .padding(.trailing, 4)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var trashControls: some View {
        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
        Text(L("ask.notes.shelf.trash")).font(.system(size: 12, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
        Spacer(minLength: 8)
        Button { model.perform { await model.restoreFromTrash()  } } label: {
            Label(L("ask.notes.trash.restore"), systemImage: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(.white)
                .background(AskTheme.accent, in: style.controlShape(height: 28))
        }
        .buttonStyle(AskPressableStyle())
        .accessibilityIdentifier("ask.notes.trash.restore")
        Button { model.perform { await model.deleteForever()  } } label: {
            Text(L("ask.notes.trash.deleteForever")).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(StudioTheme.danger)
                .background(AskTheme.hoverFill, in: style.controlShape(height: 28))
        }
        .buttonStyle(AskPressableStyle())
    }

    private func crumb(_ note: AskNote) -> String {
        if note.source == .command, !note.command.isEmpty { return note.source.title + " · " + note.command }
        return note.source.title
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(AskNotesViewModel.Mode.allCases, id: \.self) { mode in
                let active = model.mode == mode
                Button { model.perform { await model.setMode(mode)  } } label: {
                    Text(L("ask.notes.mode." + mode.rawValue))
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background {
                            if active {
                                style.controlShape(height: 24).fill(AskTheme.raisedSurface)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(style.controlShape(height: 24))
                }
                .buttonStyle(.plain)
                .help(L("ask.notes.mode." + mode.rawValue) + (mode == .edit ? " ⌘E" : mode == .split ? " ⌥⌘E" : ""))
                .accessibilityLabel(L("ask.notes.mode." + mode.rawValue))
                .accessibilityIdentifier("ask.notes.mode." + mode.rawValue)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(AskTheme.hoverFill, in: style.controlShape(height: 28))
        .fixedSize()
    }

    private func exportMenu(_ note: AskNote) -> some View {
        Menu {
            Section(L("ask.notes.exportAs")) {
                Button(L("ask.notes.export.markdown") + "  ⇧⌘E") { model.exportSelected(.markdown) }
                Button(L("ask.notes.export.html")) { model.exportSelected(.html) }
                Button(L("ask.notes.export.pdf")) { model.exportSelected(.pdf) }
            }
            Section {
                Button(L("ask.notes.copyMarkdown")) { model.copySelected() }
                Button(L("ask.plugin.action.copyRich") + "  ⇧⌘C") { model.copySelectedRich() }
            }
            Section {
                Toggle(L("ask.notes.export.frontMatter"), isOn: $model.exportOptions.frontMatter)
                if !note.input.isEmpty {
                    Toggle(L("ask.notes.export.original"), isOn: $model.exportOptions.original)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(StudioTheme.textTertiary)
        .fixedSize()
        .help(L("ask.notes.export"))
        .accessibilityLabel(L("ask.notes.export"))
        .accessibilityIdentifier("ask.notes.exportMenu")
    }

    private func moreMenu() -> some View {
        Menu {
            Button(L("ask.plugin.action.openInWindow") + "  ⌘O") { model.openSelectedInWindow() }
            if model.askAI != nil { Button(L("ask.result.askAI")) { model.askAIAboutSelected() } }
            if model.canOpenSource { Button(L("ask.notes.openConversation")) { model.openSource() } }
            if model.agentRevision != nil { Button(L("ask.notes.revertAgent")) { model.perform { await model.revertAgentChange()  } } }
            Divider()
            Button(L("ask.notes.delete") + "  ⌘⌫", role: .destructive) { model.perform { await model.deleteSelected()  } }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(StudioTheme.textTertiary)
        .fixedSize()
        .accessibilityLabel(L("ask.notes.more"))
    }

    // MARK: - Header

    private func titleField(size: CGFloat) -> some View {
        TextField(L("ask.notes.title.placeholder"), text: Binding(
            get: { titleDraft },
            set: { value in
                titleDraft = value
                if let id = titleNoteID { model.stageTitle(value, id: id) }
            }
        ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(StudioTheme.textPrimary)
            .lineLimit(1 ... 3)
            .focused(focus, equals: .title)
            .onSubmit { commitTitle(); focus.wrappedValue = nil }
            .disabled(model.selected?.isDeleted == true)
            .accessibilityIdentifier("ask.notes.title")
    }

    private func header(_ note: AskNote, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleField(size: AskLibraryLayout.titleSize(compact: compact))
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
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 72, alignment: .leading)
            content().font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
        }
    }

    private func sourceLine(_ note: AskNote) -> some View {
        let tint = AskNotesStyle.sourceColor(note.source)
        var chip = note.source.title
        if note.source == .command, !note.command.isEmpty {
            chip = note.command + (note.keyword.isEmpty ? "" : " · " + note.keyword)
        }
        var details: [String] = []
        if let model = note.model, !model.isEmpty { details.append(model) }
        if let app = note.sourceApp, !app.isEmpty { details.append(L("ask.notes.from", app)) }
        if note.author == .agent { details.append(L("ask.notes.byAgent")) }
        return HStack(spacing: 6) {
            Label(chip, systemImage: note.source.symbol).font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 7).frame(height: 21)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if !details.isEmpty { Text(details.joined(separator: " · ")).lineLimit(1).layoutPriority(-1) }
            if model.canOpenSource {
                Button(action: model.openSource) {
                    ViewThatFits(in: .horizontal) {
                        Label(L("ask.notes.openConversation"), systemImage: "arrow.uturn.backward")
                            .fixedSize()
                        Image(systemName: "arrow.uturn.backward").frame(width: 20, height: 21)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(AskTheme.accent)
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
                Button(L("ask.notes.revertAgent"), action: { model.perform { await model.revertAgentChange() } })
                    .buttonStyle(.plain).foregroundStyle(AskTheme.accent)
            }
        }
    }

    private func tagLine(_ note: AskNote) -> some View {
        AskWordBookFlow(spacing: 5) {
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Circle().fill(AskNotesStyle.tagColor(tag)).frame(width: 7, height: 7)
                    Text(tag).font(.system(size: 12)).foregroundStyle(StudioTheme.textPrimary)
                    if !note.isDeleted {
                        Button { model.perform { await model.removeTag(tag)  } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                        .accessibilityLabel(L("ask.notes.tag.remove", tag))
                    }
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(AskTheme.hoverFill, in: Capsule())
            }
            if !note.isDeleted {
                TextField(L("ask.notes.tag.add"), text: $tagDraft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .frame(width: 96)
                    .padding(.horizontal, 8).frame(height: 22)
                    .overlay(Capsule().strokeBorder(AskTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .focused(focus, equals: .tag)
                    .onSubmit { model.perform { await model.addTag(tagDraft); tagDraft = ""; focus.wrappedValue = .tag  } }
                    .accessibilityIdentifier("ask.notes.tag")
            }
        }
    }

    private func originCard(_ note: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsOriginal.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsOriginal ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L(note.source == .chat ? "ask.notes.question" : "ask.result.original")).font(.system(size: 12))
                    Spacer(minLength: 4)
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsOriginal {
                ScrollView(.vertical) {
                    Text(note.input).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 96)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(AskTheme.separator).frame(width: 2) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AskTheme.noteQuestionSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(colorScheme == .light ? AskTheme.cardBorder : AskTheme.separator,
                          lineWidth: colorScheme == .light ? 1 : 0.5))
    }

    // MARK: - Reading

    private func reading(_ note: AskNote, width: CGFloat) -> some View {
        let showsOutline = model.showsOutline && note.headings.count >= 2 && width > 720
        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    header(note, compact: width < 520)
                    Rectangle().fill(AskTheme.separator).frame(height: 0.5)
                    if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { model.beginEditing() } label: {
                            Text(L("ask.notes.emptyBody")).font(.system(size: 14))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        AskNoteReaderText(text: note.body,
                                          highlight: AskNotesViewModel.parseSearch(model.searchText).text,
                                          jump: jump, onToggleTask: note.isDeleted ? nil : { value in model.perform { await model.toggleTask(value)  } })
                            .id(note.id)
                    }
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, width < 520 ? 18 : 36).padding(.top, 6).padding(.bottom, 90)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !note.isDeleted { model.beginEditing() } }
            if showsOutline { outline(note).frame(width: Self.outlineWidth) }
        }
    }

    private func outline(_ note: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("ask.notes.outline")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(note.headings.enumerated()), id: \.element.id) { index, heading in
                        Button { jump = AskNoteJump(heading: index) } label: {
                            Text(AskNote.plainText(heading.text)).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(jump?.heading == index
                                    ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                                .padding(.leading, CGFloat(heading.level - 1) * 10 + 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(jump?.heading == index ? AskTheme.accent : AskTheme.separator)
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
            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
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
        .frame(maxWidth: Self.readingWidth + 40)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, width < 520 ? 18 : 36).padding(.top, 6).padding(.bottom, 64)
    }

    private func splitting(_ note: AskNote, width: CGFloat) -> some View {
        let stacked = width < 600
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            VStack(alignment: .leading, spacing: 12) {
                titleField(size: 20)
                formatBar
                AskMarkdownEditor(text: $model.draftBody, controller: editor)
                    .id(note.id)
            }
            .padding(.horizontal, stacked ? 18 : 24).padding(.top, 6).padding(.bottom, stacked ? 12 : 64)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            Rectangle().fill(AskTheme.separator)
                .frame(width: stacked ? nil : 0.5, height: stacked ? 0.5 : nil)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("ask.notes.preview")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                    AskNoteReaderText(text: model.draftBody)
                        .accessibilityIdentifier("ask.notes.splitPreview")
                }
                .padding(.horizontal, stacked ? 18 : 24).padding(.top, 8).padding(.bottom, 80)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var formatBar: some View {
        ViewThatFits(in: .horizontal) {
            formatButtons
            ScrollView(.horizontal, showsIndicators: false) {
                formatButtons
            }
            // Preserve the toolbar height when its controls need horizontal scrolling.
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
                Text(verbatim: "H").font(.system(size: 13, weight: .bold))
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
        .askInWindowGlass(corner: style.usesGlass ? 12 : 8, opaqueFill: AskTheme.glassFill, elevation: .control)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(AskTheme.separator).frame(width: 0.5, height: 16).padding(.horizontal, 3)
    }

    private func formatButton(_ format: AskMarkdownFormat, symbol: String, key: String?) -> some View {
        let title = L("ask.notes.format." + "\(format)")
        return AskIconGhostButton(label: title + (key.map { " " + $0 } ?? ""), systemImage: symbol) {
            editor.apply(format)
        }
    }

    // MARK: - Bars

    @ViewBuilder private func actionBar(_ note: AskNote, width: CGFloat) -> some View {
        if !note.isDeleted {
            ViewThatFits(in: .horizontal) {
                if width >= 600 { noteActions(compact: false).fixedSize(horizontal: true, vertical: false) }
                noteActions(compact: true)
            }
            .askLibraryActionSurface()
            .accessibilityIdentifier("ask.notes.actionBar")
        }
    }

    private func noteActions(compact: Bool) -> some View {
        HStack(spacing: 2) {
            if model.editing {
                let draft = AskNote(title: "", body: model.draftBody, command: "", keyword: "", input: "",
                                    createdAt: .now, updatedAt: .now)
                Text(L("ask.notes.stats.characters", draft.characterCount) + " · Markdown")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 10)
                barDivider
                barButton(L("ask.notes.done"), symbol: "checkmark", key: "⌘E", compact: compact) {
                    model.perform { await model.setMode(.read) }
                }
            } else {
                barButton(L("ask.plugin.action.copy"), symbol: "doc.on.doc", key: nil, compact: compact,
                          action: model.copySelected)
                barButton(L("ask.notes.rich"), symbol: "doc.richtext", key: "⇧⌘C", compact: compact,
                          action: model.copySelectedRich)
                if model.askAI != nil {
                    barButton(L("ask.result.askAI"), symbol: "sparkles", key: nil, compact: compact,
                              action: model.askAIAboutSelected)
                }
                barButton(L("ask.notes.edit"), symbol: "pencil", key: "⌘E", compact: compact) { model.beginEditing() }
                barDivider
                AskIconGhostButton(label: L("ask.plugin.action.openInWindow") + " ⌘O",
                                   systemImage: "macwindow.on.rectangle",
                                   action: model.openSelectedInWindow)
                AskIconGhostButton(label: L("ask.notes.delete") + " ⌘⌫", systemImage: "trash",
                                   action: { model.perform { await model.deleteSelected() } })
                    .accessibilityIdentifier("ask.notes.delete")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
    }

    private var barDivider: some View {
        Rectangle().fill(AskTheme.separator).frame(width: 0.5, height: 16).padding(.horizontal, 4)
    }

    private func barButton(_ title: String, symbol: String, key: String?, compact: Bool = false,
                           action: @escaping () -> Void) -> some View {
        AskLibraryBarButton(title: title, symbol: symbol, key: key, compact: compact, action: action)
    }

    // MARK: - Picking and empty

    private var picking: some View {
        let chosen = model.pickedNotes
        return VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(AskTheme.accent)
                .frame(width: 64, height: 64)
                .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(L("ask.notes.picked", chosen.count)).font(.system(size: 17, weight: .semibold))
            Text(chosen.prefix(6).map(\.title).joined(separator: "、") + (chosen.count > 6 ? "…" : ""))
                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Text(L("ask.notes.pickHint")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            ViewThatFits(in: .horizontal) {
                batchActions(count: chosen.count, compact: false).fixedSize(horizontal: true, vertical: false)
                batchActions(count: chosen.count, compact: true)
            }
            .disabled(chosen.isEmpty)
            .padding(.horizontal, 6)
            .frame(height: 40)
            .askInWindowGlass(corner: style.usesGlass ? 20 : 10, opaqueFill: AskTheme.glassFill)
            .overlay(RoundedRectangle(cornerRadius: style.usesGlass ? 20 : 10, style: .continuous)
                .strokeBorder(AskTheme.accent.opacity(0.45), lineWidth: 1))
            .padding(.bottom, 16)
            .accessibilityIdentifier("ask.notes.batchBar")
        }
    }

    private func batchActions(count: Int, compact: Bool) -> some View {
        HStack(spacing: 2) {
            Text(L("ask.notes.count", count)).font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 10)
            barDivider
            barButton(L("ask.notes.batch.tag"), symbol: "tag", key: nil, compact: compact) { showsBatchTag = true }
                .popover(isPresented: $showsBatchTag, arrowEdge: .top) {
                    HStack {
                        TextField(L("ask.notes.tag.add"), text: $batchTag).textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit { model.perform { await model.tagPicked(batchTag); batchTag = ""; showsBatchTag = false  } }
                    }
                    .padding(10)
                }
            barButton(L("ask.notes.pin"), symbol: "pin", key: nil, compact: compact, action: { model.perform { await model.pinPicked() } })
            barButton(L("ask.notes.batch.copy"), symbol: "doc.on.doc", key: nil, compact: compact,
                      action: model.copyPicked)
            barButton(L("ask.notes.batch.export"), symbol: "square.and.arrow.up", key: nil, compact: compact,
                      action: model.exportPicked)
            barDivider
            AskLibraryBarButton(title: L("ask.notes.delete"), symbol: "trash", key: nil, danger: true, compact: compact,
                              action: { model.perform { await model.trashPicked() } })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.inTrash ? "trash" : "note.text").font(.system(size: 28))
                .foregroundStyle(AskTheme.accent)
                .frame(width: 64, height: 64)
                .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if model.inTrash {
                Text(L("ask.notes.trash.none")).font(.system(size: 14)).foregroundStyle(StudioTheme.textSecondary)
            } else {
                Text(L("ask.notes.emptyTitle")).font(.system(size: 17, weight: .semibold))
                Text(L("ask.notes.emptySubtitle")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                VStack(alignment: .leading, spacing: 8) {
                    tip("bubble.left", L("ask.notes.tip.chat"))
                    tip("wand.and.stars", L("ask.notes.tip.command"))
                    tip("square.and.pencil", L("ask.notes.tip.new"))
                }
                .frame(width: 380)
                .padding(.top, 8)
                Button { model.perform { await model.createNote()  } } label: {
                    Label(L("ask.notes.new"), systemImage: "plus").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                        .background(AskTheme.accent, in: style.controlShape(height: 30))
                }
                .buttonStyle(AskPressableStyle())
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(AskTheme.accent).frame(width: 18)
            Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
