// swiftlint:disable file_length
import SwiftUI
import UniformTypeIdentifiers

/// ④ Output: how the launcher shows what the script printed, what happens after a
/// run succeeds or fails, and the launcher as it would look, with what this run
/// would do. See `docs/design/workflow-gallery-output-actions.md` §3.5.
struct AskWorkflowOutputForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private var menu: AskWorkflowOutputMenu? {
        model.outputMenu
    }

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    private var output: AskWorkflowManifest.Output {
        manifest?.output ?? .init()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                AskWorkflowFormSection(title: L("ask.workflow.editor.output"),
                                       hint: L("ask.workflow.editor.output.hint")) {
                    AskWorkflowRadioList(choices: Self.displayChoices, selection: output.display, stacked: true) {
                        model.setDisplay($0)
                    }
                }
                actionSection(.onSuccess)
                actionSection(.onFailure)
                AskWorkflowFormSection(title: L("ask.workflow.editor.output.after"), hint: nil) {
                    VStack(spacing: 0) {
                        toggleRow(
                            L("ask.workflow.editor.output.close"),
                            detail: L("ask.workflow.editor.output.closeDetail"),
                            isOn: output.closes,
                            locked: output.display == .none
                        ) {
                            model.setOutputFlag("close", $0)
                        }
                        Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                        toggleRow(L("ask.workflow.editor.output.scriptActions"),
                                  detail: L("ask.workflow.editor.output.scriptActionsDetail"),
                                  isOn: output.scriptActions, locked: false) {
                            model.setOutputFlag("scriptActions", $0)
                        }
                    }
                    .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border))
                }
                askWorkflowProblemsText(model.problems(for: .output).filter { !$0.field.hasPrefix("output.on") })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                AskWorkflowFormSection(title: L("ask.workflow.editor.preview.title"),
                                       hint: L("ask.workflow.editor.preview.hint")) {
                    AskWorkflowLauncherPreview(
                        name: manifest?.name ?? "", keyword: manifest?.keywords.first?.keyword ?? "",
                        query: model.lastRun?.input
                            .query ?? (model.testQuery.isEmpty ? "100 usd jpy" : model.testQuery),
                        result: model.lastRun.flatMap { $0.succeeded ? $0 : nil },
                        output: output, timeout: manifest?.timeout ?? AskWorkflowManifest.defaultTimeout
                    )
                }
                AskWorkflowWillRun(
                    steps: model.successPreview,
                    closes: output.closes,
                    scriptActions: output.scriptActions
                )
            }
            // The design's 1.25 : 1 split at the editor's usual width; the form takes what is left.
            .frame(width: Self.previewWidth, alignment: .leading)
        }
        .onExitCommand { model.outputMenu = nil }
    }

    static let previewWidth: CGFloat = 330

    static var displayChoices: [AskWorkflowChoice<AskWorkflowManifest.Output.Display>] {
        AskWorkflowManifest.Output.Display.allCases.map { display in
            AskWorkflowChoice(value: display, title: L("ask.workflow.editor.output." + display.rawValue),
                              detail: L("ask.workflow.editor.outputDetail." + display.rawValue),
                              comingSoon: !display.isSupported)
        }
    }

    // MARK: - Actions

    private func actionSection(_ list: AskWorkflowEditorModel.ActionList) -> some View {
        let count = model.actions(list).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("ask.workflow.editor.output." + list.rawValue)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                if count > 0 {
                    Text(L("ask.workflow.editor.actionsCount", count)).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            AskWorkflowActionHint(list: list).padding(.horizontal, 4).padding(.top, 3)
            AskWorkflowActionList(model: model, list: list, menu: $model.outputMenu).padding(.top, 10)
        }
        .zIndex(menu.map { Self.list(of: $0) == list } == true ? 1 : 0)
    }

    private static func list(of menu: AskWorkflowOutputMenu) -> AskWorkflowEditorModel.ActionList {
        switch menu {
        case let .add(list), let .placeholder(list, _, _): list
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Bool, locked: Bool,
                           set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: set)).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(locked)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// "Runs in order. Fields can use placeholders, such as {output}."
private struct AskWorkflowActionHint: View {
    var list: AskWorkflowEditorModel.ActionList

    var body: some View {
        HStack(spacing: 4) {
            Text(L("ask.workflow.editor.output." + list.rawValue + "Hint"))
            if list == .onSuccess {
                AskWorkflowTokenChip(text: "{output}")
            } else {
                AskWorkflowTokenChip(text: "{error}")
            }
        }
        .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
    }
}

/// One list of actions in a card: rows that can be dragged into a new order, then
/// "+ Add action" with its menu.
struct AskWorkflowActionList: View {
    @ObservedObject var model: AskWorkflowEditorModel
    var list: AskWorkflowEditorModel.ActionList
    @Binding var menu: AskWorkflowOutputMenu?
    @State private var dragging: Int?

    private var rows: [[String: Any]] {
        model.actions(list)
    }

    private var problems: [String: String] {
        let prefix = "output." + list.rawValue
        return Dictionary(
            model.problems(for: .output).filter { $0.field.hasPrefix(prefix) }.map { ($0.field, $0.message) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                }
                AskWorkflowActionRow(model: model, list: list, index: index, row: row, menu: $menu,
                                     problem: problems["output.\(list.rawValue)[\(index)]"]) {
                    dragging = index
                    return NSItemProvider(object: "\(index)" as NSString)
                }
                .zIndex(menuIsOn(index) ? 1 : 0)
                .onDrop(of: [UTType.text], delegate: ActionDrop(target: index, dragging: $dragging) { source, target in
                    model.moveAction(from: source, to: target, in: list)
                })
            }
            if rows.isEmpty {
                Text(L("ask.workflow.editor.output." + list.rawValue + "Empty")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 14).padding(.vertical, 12)
            }
            Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
            Button { menu = menu == .add(list) ? nil : .add(list) } label: {
                Label(L("ask.workflow.editor.output.addAction"), systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ModelVisualStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(rows.count >= AskWorkflowManifest.Output.maximumActions)
            .help(rows.count >= AskWorkflowManifest.Output.maximumActions
                ? L("ask.workflow.problem.tooManyActions", AskWorkflowManifest.Output.maximumActions) : "")
            .accessibilityIdentifier("ask.workflow.editor.output.add." + list.rawValue)
        }
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
        .overlay(alignment: .bottomLeading) {
            if menu == .add(list) {
                AskWorkflowAddActionMenu { kind in
                    model.addAction(kind, to: list)
                    menu = nil
                }
                .offset(x: 2, y: -44)
            }
        }
    }

    /// The placeholder menu is open on a field of this row, so the row draws above the next ones.
    private func menuIsOn(_ index: Int) -> Bool {
        if case let .placeholder(menuList, menuIndex, _) = menu {
            menuList == list && menuIndex == index
        } else {
            false
        }
    }

    /// Moves the dragged row onto the row it is dropped on.
    private struct ActionDrop: DropDelegate {
        var target: Int
        @Binding var dragging: Int?
        var move: (Int, Int) -> Void

        func performDrop(info _: DropInfo) -> Bool {
            defer { dragging = nil }
            guard let dragging, dragging != target else { return false }
            move(dragging, target)
            return true
        }
    }
}

/// One action: handle, icon and name (with a note when it needs a permission), its
/// fields, and remove.
struct AskWorkflowActionRow: View {
    @ObservedObject var model: AskWorkflowEditorModel
    var list: AskWorkflowEditorModel.ActionList
    var index: Int
    var row: [String: Any]
    @Binding var menu: AskWorkflowOutputMenu?
    var problem: String?
    /// Starts dragging the row by its handle.
    var drag: () -> NSItemProvider

    private var name: String {
        row["action"] as? String ?? ""
    }

    private var kind: AskWorkflowAction.Kind? {
        AskWorkflowAction.Kind(rawValue: name)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 14).padding(.top, 7).help(L("ask.workflow.editor.keywords.drag"))
                .onDrag(drag)
            AskWorkflowActionTile(kind: kind, size: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(kind?.title ?? name).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if kind == .notify {
                        AskWorkflowNoteChip(text: L("ask.workflow.editor.output.notifyPermission"))
                    }
                }
                .frame(minHeight: 26)
                if let kind {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(kind.fields, id: \.self) { field in
                            HStack(spacing: 8) {
                                Text(field.title).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                                    .frame(width: 44, alignment: .leading)
                                AskWorkflowPlaceholderField(
                                    value: row[field.rawValue] as? String ?? "",
                                    placeholder: field == .language ? L("ask.workflow.editor.output.languageAuto")
                                        : field == .title ? L("ask.workflow.editor.output.titleDefault") : "",
                                    insertsPlaceholders: field != .language,
                                    commit: { model.setActionField(field, to: $0, at: index, in: list) },
                                    insert: { toggleMenu(field) }
                                )
                                // Opens upwards, like "+ Add action", so a row near the bottom keeps it on screen.
                                .overlay(alignment: .bottomTrailing) {
                                    if menu == .placeholder(list, index: index, field: field) {
                                        AskWorkflowPlaceholderMenu(values: model.placeholderValues,
                                                                   failure: list == .onFailure) { token in
                                            insert(token, into: field)
                                        }
                                        .offset(y: -34)
                                    }
                                }
                            }
                            .zIndex(menu == .placeholder(list, index: index, field: field) ? 1 : 0)
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.removeAction(at: index, from: list) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary).padding(.top, 2)
            .help(L("ask.workflow.editor.output.removeAction"))
            .accessibilityLabel(L("ask.workflow.editor.output.removeAction"))
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 10)
        .background(problem == nil ? Color.clear : StudioTheme.danger.opacity(0.06))
        .contentShape(Rectangle())
    }

    private func toggleMenu(_ field: AskWorkflowAction.Field) {
        let target = AskWorkflowOutputMenu.placeholder(list, index: index, field: field)
        menu = menu == target ? nil : target
    }

    /// Adds `token` at the end of the field, in place of a `{` just typed to open the menu.
    private func insert(_ token: String, into field: AskWorkflowAction.Field) {
        let current = row[field.rawValue] as? String ?? ""
        let base = current.hasSuffix("{") ? String(current.dropLast()) : current
        model.setActionField(field, to: base + token, at: index, in: list)
        menu = nil
    }
}

/// A field whose placeholders show as small tags until it is clicked to edit. Typing
/// `{` opens the placeholder menu, like "{ } Insert".
struct AskWorkflowPlaceholderField: View {
    var value: String
    var placeholder: String
    var insertsPlaceholders = true
    var commit: (String) -> Void
    var insert: () -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if editing {
                    TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit { focused = false }
                } else {
                    AskWorkflowPlaceholderText(text: value, placeholder: placeholder)
                        .contentShape(Rectangle())
                        .onTapGesture { edit() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            if insertsPlaceholders {
                Button(action: insert) {
                    Text(L("ask.workflow.editor.output.insert")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(ModelVisualStyle.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityLabel(L("ask.workflow.editor.output.insertHelp"))
            }
        }
        .padding(.leading, 8).padding(.trailing, 5).padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? AskTheme.accent : ModelVisualStyle.border))
        .onAppear { text = value }
        .onChange(of: value) { newValue in
            if !focused {
                text = newValue
            }
        }
        .onChange(of: text) { [text] newValue in
            guard focused, newValue != value else { return }
            commit(newValue)
            if insertsPlaceholders, newValue.count == text.count + 1, newValue.hasSuffix("{") {
                insert()
            }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused {
                editing = false
            }
        }
    }

    private func edit() {
        text = value
        editing = true
        DispatchQueue.main.async { focused = true }
    }
}

/// Text with its `{placeholders}` as tags.
struct AskWorkflowPlaceholderText: View {
    var text: String
    var placeholder = ""

    var body: some View {
        if text.isEmpty {
            Text(placeholder).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
        } else {
            AgentFlowLayout(spacing: 3) {
                ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                    if segment.isToken {
                        AskWorkflowTokenChip(text: segment.text)
                    } else {
                        Text(segment.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    struct Segment: Equatable {
        var text: String
        var isToken: Bool
    }

    /// `"Copied {output.line1}!"` → text, token, text.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex {
                segments.append(Segment(text: String(rest[..<open]), isToken: false))
            }
            segments.append(Segment(text: String(rest[open ... close]), isToken: true))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty {
            segments.append(Segment(text: String(rest), isToken: false))
        }
        return segments
    }
}

/// A `{placeholder}` as a small accent tag.
struct AskWorkflowTokenChip: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(AskTheme.accent)
            .padding(.horizontal, 6).frame(height: 18)
            .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1).fixedSize()
    }
}

/// An orange note next to a name: "Asks for notification permission the first time".
struct AskWorkflowNoteChip: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(StudioTheme.warning)
            .padding(.horizontal, 6).frame(height: 17)
            .background(StudioTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1).fixedSize()
    }
}

/// An action's icon on its colour: copy blue, write back green, notify orange, open purple.
struct AskWorkflowActionTile: View {
    var kind: AskWorkflowAction.Kind?
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: kind?.symbol ?? "questionmark")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Self.color(kind))
            .frame(width: size, height: size)
            .background(
                Self.color(kind).opacity(0.16),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
    }

    static func color(_ kind: AskWorkflowAction.Kind?) -> Color {
        switch kind {
        case .copy: AskTheme.accent
        case .writeBack: StudioTheme.success
        case .notify: StudioTheme.warning
        case .open, .askAI: AskWorkflowEditorStyle.assistant
        case .hud, .reveal, .speak, nil: StudioTheme.textSecondary
        }
    }
}

/// A floating menu card like the design's pop-ups.
private struct AskWorkflowMenuCard<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(6)
            .frame(width: width, alignment: .leading)
            .background(StudioTheme.modalSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "+ Add action": common, open, more; each with what it asks for.
struct AskWorkflowAddActionMenu: View {
    var pick: (AskWorkflowAction.Kind) -> Void

    var body: some View {
        AskWorkflowMenuCard(width: 300) {
            ForEach(Array(AskWorkflowAction.Kind.groups.enumerated()), id: \.offset) { index, group in
                Text(L("ask.workflow.editor.output.group\(index)")).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 8).padding(.top, 6).padding(
                        .bottom,
                        3
                    )
                ForEach(group, id: \.self) { kind in
                    AskWorkflowMenuItem {
                        pick(kind)
                    } label: {
                        HStack(spacing: 10) {
                            AskWorkflowActionTile(kind: kind, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary)
                                Text(kind.fields.map(\.title)
                                    .joined(separator: L("ask.workflow.editor.output.fieldSeparator")))
                                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                            }
                        }
                    }
                    .accessibilityIdentifier("ask.workflow.editor.output.addMenu." + kind.rawValue)
                }
            }
        }
    }
}

/// "{ } Insert": every placeholder with what it means and its value from the last test run.
struct AskWorkflowPlaceholderMenu: View {
    var values: AskWorkflowPlaceholders
    var failure: Bool
    var pick: (String) -> Void

    /// One row: the token, what it is, and its value now.
    struct Row: Equatable {
        var token: String
        var title: String
        var value: String
    }

    static func rows(values: AskWorkflowPlaceholders, failure: Bool) -> [Row] {
        var rows: [Row] = []
        for name in AskWorkflowPlaceholders.names {
            switch name {
            case "json.":
                let key = Self.firstJSONKey(in: values.output) ?? "field"
                let token = "json." + key
                rows.append(Row(token: "{\(token)}", title: L("ask.workflow.editor.placeholder.json"),
                                value: values.value(of: Substring(token)) ?? ""))
            case "option:":
                let options = values.options.isEmpty ? ["name": ""] : values.options
                for key in options.keys.sorted() {
                    rows.append(Row(token: "{option:\(key)}", title: L("ask.workflow.editor.placeholder.option"),
                                    value: options[key] ?? ""))
                }
            case "error":
                if failure {
                    rows.append(Row(token: "{error}", title: L("ask.workflow.editor.placeholder.error"),
                                    value: values.error ?? ""))
                }
            default:
                rows.append(Row(token: "{\(name)}", title: L("ask.workflow.editor.placeholder." + name),
                                value: values.value(of: Substring(name)) ?? ""))
            }
        }
        return rows
    }

    /// The first key of stdout read as a JSON object, to suggest `{json.key}`.
    static func firstJSONKey(in output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.keys.sorted().first
    }

    var body: some View {
        AskWorkflowMenuCard(width: 316) {
            Text(L("ask.workflow.editor.placeholder.menuTitle")).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
            ForEach(Array(Self.rows(values: values, failure: failure).enumerated()), id: \.offset) { _, row in
                AskWorkflowMenuItem {
                    pick(row.token)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.token).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Text(row.title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(row.value.isEmpty ? L("ask.workflow.editor.placeholder.empty")
                            : AskWorkflowActionRunner.clipped(row.value, limit: 24))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// A row in a menu card, highlighted under the pointer.
private struct AskWorkflowMenuItem<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? AskTheme.accent.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "This run would…": each success action with its filled-in value, then whether
/// the launcher closes.
struct AskWorkflowWillRun: View {
    var steps: [AskWorkflowActionStep]
    var closes: Bool
    var scriptActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("ask.workflow.editor.willRun.title")).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
            if steps.isEmpty {
                Text(L("ask.workflow.editor.willRun.none")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                line(marker: "\(index + 1)", title: step.title,
                     value: step.problem ?? step.detail.replacingOccurrences(of: "\n", with: " ⏎ "),
                     failed: step.problem != nil)
            }
            if closes {
                line(marker: "→", title: L("ask.workflow.editor.willRun.close"), value: nil, failed: false)
            }
            if scriptActions {
                line(marker: "+", title: L("ask.workflow.editor.willRun.script"), value: nil, failed: false)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
    }

    private func line(marker: String, title: String, value: String?, failed: Bool) -> some View {
        HStack(spacing: 8) {
            Text(marker).font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 16, height: 16).background(StudioTheme.controlSurface, in: Circle())
            Text(title).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1).fixedSize()
            if let value {
                Text(value).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(failed ? StudioTheme.danger : StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}
