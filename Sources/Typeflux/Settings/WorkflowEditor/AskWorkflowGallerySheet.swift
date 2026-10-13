// swiftlint:disable file_length
import SwiftUI

/// The gallery (§1.2): categories and search on the left, example cards on the right;
/// a card opens its detail page, and an added example with a newer version opens the
/// differences before anything is overwritten.
struct AskWorkflowGallerySheet: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var store: AskWorkflowStore
    var gallery: AskWorkflowGallery
    var builtIn: [AskKeyword]
    /// Opens an added example in the editor.
    var open: (String) -> Void
    var done: () -> Void

    @State private var category: AskWorkflowGallery.Category?
    @State private var search = ""
    @State private var selected: String?
    @State private var updating: String?
    @State private var note: String?
    @State private var failure: String?
    /// Runtimes not found on this Mac; nil until looked up.
    @State private var missing: Set<AskWorkflowRuntime>?

    init(store: AskWorkflowStore, gallery: AskWorkflowGallery = .bundled, builtIn: [AskKeyword],
         selected: String? = nil, updating: String? = nil, missing: Set<AskWorkflowRuntime>? = nil,
         open: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.store = store
        self.gallery = gallery
        self.builtIn = builtIn
        self.open = open
        self.done = done
        _selected = State(initialValue: selected)
        _updating = State(initialValue: updating)
        _missing = State(initialValue: missing)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Rectangle().fill(TypefluxColor.separator.color).frame(width: 1)
            ZStack(alignment: .topTrailing) {
                Group {
                    if let id = updating, let item = gallery.item(id), let update = store.galleryUpdate(item) {
                        updateView(item, update)
                    } else if let id = selected, let item = gallery.item(id) {
                        ScrollView { detail(item).padding(24) }
                    } else {
                        ScrollView { grid.padding(24) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Button(action: done) {
                    Image(systemName: "xmark").font(.system(.callout, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(12)
                .accessibilityLabel(L("ask.workflow.editor.close"))
            }
        }
        .frame(width: 980, height: 640)
        .background(TypefluxColor.windowBackground.color)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard missing == nil else { return }
            let path = await AskWorkflowPath.searchPath()
            missing = Self.missingRuntimes(gallery.items.map(\.runtime), searchPath: path)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("ask.workflow.gallery.title")).font(.system(.title2, weight: .semibold))
                .foregroundStyle(TypefluxColor.label.color)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(TypefluxColor.tertiaryLabel.color)
                TextField(L("ask.workflow.gallery.search"), text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("ask.workflow.gallery.search")
            }
            .font(.system(.callout)).padding(.horizontal, 9).frame(height: 30)
            .background(
                TypefluxColor.controlBackground.color,
                in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                .strokeBorder(TypefluxColor.separator.color))
            .padding(.top, 16)
            VStack(spacing: 2) {
                categoryRow(nil, title: L("ask.workflow.gallery.category.all"), count: gallery.items.count)
                ForEach(gallery.categoryCounts, id: \.category) { entry in
                    categoryRow(entry.category, title: entry.category.title, count: entry.count)
                }
            }
            .padding(.top, 14)
            Spacer()
            if let note {
                Label(note, systemImage: "checkmark.circle.fill").font(.system(.callout))
                    .foregroundStyle(TypefluxColor.success.color).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.workflow.gallery.note")
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(.callout))
                    .foregroundStyle(TypefluxColor.danger.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TypefluxColor.controlBackground.color)
    }

    private func categoryRow(_ value: AskWorkflowGallery.Category?, title: String, count: Int) -> some View {
        let isSelected = category == value && selected == nil && updating == nil
        return Button {
            category = value
            selected = nil
            updating = nil
        } label: {
            HStack {
                Text(title).font(.system(.body, weight: isSelected ? .semibold : .regular))
                Spacer()
                Text("\(count)").font(.system(.callout)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            .foregroundStyle(TypefluxColor.label.color)
            .padding(.horizontal, 12).frame(height: 34)
            .background(isSelected ? TypefluxColor.accent.color.opacity(0.12) : .clear,
                        in: RoundedRectangle(
                            cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                            style: .continuous
                        ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ask.workflow.gallery.category." + (value?.rawValue ?? "all"))
    }

    // MARK: - Cards

    private var grid: some View {
        let items = gallery.filtered(category: category, query: search)
        return Group {
            if items.isEmpty {
                Text(L("ask.workflow.gallery.noResults")).font(.system(.body))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 3),
                          spacing: 14) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.top, 14)
            }
        }
    }

    private func card(_ item: AskWorkflowGallery.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AskWorkflowGalleryTile(item: item, size: 30)
                Text(item.name).font(.system(.body, weight: .semibold)).foregroundStyle(TypefluxColor.label.color)
                    .lineLimit(2)
                    .help(item.name)
                Spacer(minLength: 0)
            }
            .frame(height: 36, alignment: .leading)
            Text(item.summary).font(.system(.callout)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if missing?.contains(item.runtime) != true {
                    Text(item.runtime.title).font(.system(.callout)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .fixedSize()
                }
                tags(item)
            }
            .frame(height: 21, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask.workflow.gallery.metadata." + item.id)
            HStack(spacing: 8) {
                cardKeywords(item)
                Spacer(minLength: 0)
                cardButton(item).fixedSize().layoutPriority(1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ask.workflow.gallery.action." + item.id)
            }
            .frame(height: 24)
        }
        .padding(14).frame(maxWidth: .infinity).frame(height: 180)
        .background(
            TypefluxColor.contentBackground.color,
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
        .contentShape(RoundedRectangle(
            cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
            style: .continuous
        ))
        .onTapGesture { selected = item.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.workflow.gallery.card." + item.id)
    }

    /// Keep the action visible; extra keywords remain available in the tooltip and detail page.
    private func cardKeywords(_ item: AskWorkflowGallery.Item) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0) }
            }
            .fixedSize()
            HStack(spacing: 4) {
                if let first = item.keywords.first {
                    Text(first).font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(TypefluxColor.label.color).lineLimit(1)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(
                            TypefluxColor.controlBackground.color,
                            in: RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                        )
                        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                            .strokeBorder(TypefluxColor.separator.color))
                }
                if item.keywords.count > 1 {
                    AskWorkflowChip(text: "+\(item.keywords.count - 1)")
                }
            }
        }
        .help(item.keywords.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.keywords.joined(separator: ", "))
        .accessibilityIdentifier("ask.workflow.gallery.keywords." + item.id)
    }

    /// "Network" for examples that reach the network, "Needs Node" when its runtime is missing.
    @ViewBuilder private func tags(_ item: AskWorkflowGallery.Item) -> some View {
        if !item.hosts.isEmpty {
            AskWorkflowGalleryTag(text: L("ask.workflow.gallery.network"), color: .orange).fixedSize()
        }
        if missing?.contains(item.runtime) == true {
            AskWorkflowGalleryTag(
                text: L("ask.workflow.gallery.needs", item.runtime.title),
                color: TypefluxColor.warning.color
            )
            .fixedSize()
            .help(L("ask.workflow.gallery.install." + item.runtime.rawValue))
        }
    }

    @ViewBuilder private func cardButton(_ item: AskWorkflowGallery.Item) -> some View {
        if store.hasUpdate(item) {
            Button(L("ask.workflow.gallery.viewUpdate")) { updating = item.id }
                .buttonStyle(.bordered).controlSize(.small)
        } else if store.installed(item) != nil {
            AskWorkflowGalleryTag(text: L("ask.workflow.gallery.added"), color: TypefluxColor.success.color)
        } else {
            Button(L("ask.workflow.gallery.add")) { add(item) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("ask.workflow.gallery.add." + item.id)
        }
    }
}

/// The detail page, the update's differences and what adding does.
extension AskWorkflowGallerySheet {
    // MARK: - Detail

    private func detail(_ item: AskWorkflowGallery.Item) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { selected = nil } label: {
                Text("‹ " + L("ask.workflow.gallery.title")).font(.system(.callout))
                    .foregroundStyle(TypefluxColor.accent.color)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.workflow.gallery.back")
            HStack(alignment: .top, spacing: 14) {
                AskWorkflowGalleryTile(item: item, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(.title2, weight: .semibold)).foregroundStyle(TypefluxColor.label.color)
                    Text(item.summary).font(.system(.body)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                detailButtons(item)
            }
            .padding(.trailing, 28)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    section(L("ask.workflow.gallery.info")) { facts(item) }
                    if !item.usage.isEmpty {
                        section(L("ask.workflow.gallery.usage")) { usage(item) }
                    }
                }
                .frame(width: 330)
                VStack(alignment: .leading, spacing: 18) {
                    if let preview = item.preview {
                        section(L("ask.workflow.gallery.inLauncher")) { launcherPreview(item, preview) }
                    }
                    if let script = item.entryScript {
                        section(script) { code(item, script) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func detailButtons(_ item: AskWorkflowGallery.Item) -> some View {
        HStack(spacing: 8) {
            if let installed = store.installed(item) {
                AskWorkflowGalleryTag(text: L("ask.workflow.gallery.added"), color: TypefluxColor.success.color)
                if store.hasUpdate(item) {
                    Button(L("ask.workflow.gallery.viewUpdate")) { updating = item.id }
                        .buttonStyle(.bordered)
                }
                Button(L("ask.workflow.gallery.openInEditor")) { open(installed.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ask.workflow.gallery.open")
            } else {
                Button(L("ask.workflow.gallery.addToMine")) { add(item) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ask.workflow.gallery.addDetail")
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.callout, weight: .semibold)).foregroundStyle(TypefluxColor.secondaryLabel.color)
            content()
        }
    }

    private func facts(_ item: AskWorkflowGallery.Item) -> some View {
        let rows: [(String, AnyView)] = [
            (L("ask.workflow.trust.keywords"), AnyView(AskFlowLayout(spacing: 5) {
                ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0) }
                Text(L("ask.workflow.gallery.renameHint", (item.keywords.first ?? "fx") + "2"))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            })),
            (L("ask.workflow.gallery.runtime"), AnyView(Text(runtimeText(item)))),
            (L("ask.workflow.gallery.does"), AnyView(AskFlowLayout(spacing: 5) {
                ForEach(item.hosts, id: \.self) { host in
                    AskWorkflowGalleryTag(text: L("ask.workflow.gallery.visits", host), color: .orange)
                }
                ForEach(Array(Self.actions(item).enumerated()), id: \.offset) { _, title in
                    AskWorkflowGalleryTag(text: title, color: TypefluxColor.secondaryLabel.color)
                }
                if item.hosts.isEmpty, Self.actions(item).isEmpty {
                    Text(L("ask.workflow.gallery.showsOnly"))
                }
            })),
            (L("ask.workflow.gallery.demonstrates"), AnyView(Text(item.demonstrates))),
            (L("ask.workflow.trust.files"), AnyView(Text(item.files().keys.filter { $0 != AskWorkflowManifest.fileName }
                    .sorted().joined(separator: " · ")).font(.system(.callout, design: .monospaced))))
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0).foregroundStyle(TypefluxColor.tertiaryLabel.color).frame(width: 76, alignment: .leading)
                    row.1.foregroundStyle(TypefluxColor.label.color).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.callout)).padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .background(
            TypefluxColor.contentBackground.color,
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
    }

    /// "Python 3 (comes with macOS, nothing to install)", or how to get it when it is missing.
    private func runtimeText(_ item: AskWorkflowGallery.Item) -> String {
        if missing?.contains(item.runtime) == true {
            return L("ask.workflow.gallery.install." + item.runtime.rawValue)
        }
        return L("ask.workflow.gallery.runtime." + item.runtime.rawValue)
    }

    /// What the example does after a run, from its actions: "Copy to clipboard", "Send notification";
    /// a list says it is one, since its rows do the rest.
    static func actions(_ item: AskWorkflowGallery.Item) -> [String] {
        var seen = Set<String>()
        let list = item.manifest.output.display == .items ? [L("ask.workflow.gallery.list")] : []
        return list + (item.manifest.output.onSuccess + item.manifest.output.onFailure).compactMap(\.kind?.title)
            .filter { seen.insert($0).inserted }
    }

    private func usage(_ item: AskWorkflowGallery.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.usage, id: \.example) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AskWorkflowChip(text: line.example)
                    Text(line.description).font(.system(.callout)).foregroundStyle(TypefluxColor.label.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TypefluxColor.contentBackground.color,
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
    }

    private func launcherPreview(_ item: AskWorkflowGallery.Item,
                                 _ preview: AskWorkflowGallery.Item.Preview) -> some View {
        let input = AskWorkflowTestInput(query: preview.query, selection: preview.selection, keyword: preview.keyword)
        let result = AskWorkflowTestResult(input: input, exitCode: 0, stdout: preview.output, stderr: "", duration: 0)
        return AskWorkflowLauncherPreview(
            name: item.name, keyword: preview.keyword, query: preview.query, result: result,
            output: AskWorkflowManifest.Output(display: Self.previewDisplay(item)), timeout: item.manifest.timeout,
            folder: item.folder
        )
        .background(
            TypefluxColor.contentBackground.color,
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
    }

    /// How the sample output shows: as the example shows it, and as text for one that shows
    /// nothing (its sample is what it copies).
    static func previewDisplay(_ item: AskWorkflowGallery.Item) -> AskWorkflowManifest.Output.Display {
        item.manifest.output.display == .none ? .text : item.manifest.output.display
    }

    /// The entry script's first lines, without its `#!` line, unwrapped.
    private func code(_ item: AskWorkflowGallery.Item, _ script: String) -> some View {
        let text = item.files()[script].flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(Self.preview(text)).font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(TypefluxColor.label.color).textSelection(.enabled)
                .fixedSize().padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(
                        cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                        style: .continuous
                    ))
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
    }

    static let previewLines = 20

    /// The runtimes among `runtimes` with no program on `searchPath`.
    static func missingRuntimes(_ runtimes: [AskWorkflowRuntime], searchPath: String) -> Set<AskWorkflowRuntime> {
        Set(runtimes.filter { runtime in
            runtime.interpreterName.map { AskWorkflowPath.resolve($0, searchPath: searchPath) == nil } ?? false
        })
    }

    /// What adding said: the example's name, and the keywords it had to rename.
    static func addedNote(_ item: AskWorkflowGallery.Item, _ addition: AskWorkflowStore.GalleryAddition) -> String {
        guard !addition.renamed.isEmpty else { return L("ask.workflow.gallery.addedNote", item.name) }
        let renamed = addition.renamed.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
        return L("ask.workflow.gallery.addedRenamed", item.name, renamed.joined(separator: ", "))
    }

    /// The first lines of a script as the detail page shows them: the `#!` line left out.
    static func preview(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("#!") == true {
            lines.removeFirst()
        }
        return lines.prefix(previewLines).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Update

    private func updateView(_ item: AskWorkflowGallery.Item, _ update: AskWorkflowStore.GalleryUpdate) -> some View {
        let version = store.installed(item)?.manifest?.origin?.version ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            Button { updating = nil } label: {
                Text("‹ " + item.name).font(.system(.callout)).foregroundStyle(TypefluxColor.accent.color)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(L("ask.workflow.gallery.update.title", item.name, version, item.version))
                    .font(.system(.title2, weight: .semibold)).foregroundStyle(TypefluxColor.label.color)
                Spacer()
                Button(L("ask.workflow.cancel")) { updating = nil }
                    .buttonStyle(.bordered)
                Button(L("ask.workflow.gallery.update.apply")) { applyUpdate(item) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ask.workflow.gallery.update.apply")
            }
            .padding(.trailing, 30)
            Text(update.userModified.isEmpty ? L("ask.workflow.gallery.update.hint")
                : L("ask.workflow.gallery.update.modified", update.userModified.sorted().joined(separator: ", ")))
                .font(.system(.callout))
                .foregroundStyle(update.userModified.isEmpty ? TypefluxColor.secondaryLabel.color : TypefluxColor
                    .warning.color)
                .fixedSize(horizontal: false, vertical: true)
            AskWorkflowDiffView(old: update.current, new: update.updated, labels: (
                L("ask.workflow.gallery.update.mine"), L("ask.workflow.gallery.update.new")
            ), suffix: L("ask.workflow.editor.diff.diffSuffix"), marked: update.userModified,
            markHint: L("ask.workflow.gallery.update.markHint")) { EmptyView() }
                .clipShape(RoundedRectangle(
                    cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                    style: .continuous
                ))
                .overlay(RoundedRectangle(
                    cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                    style: .continuous
                )
                .strokeBorder(TypefluxColor.separator.color))
        }
        .padding(24)
    }

    // MARK: - Actions

    private func add(_ item: AskWorkflowGallery.Item) {
        do {
            let addition = try store.add(item, builtIn: builtIn)
            failure = nil
            note = Self.addedNote(item, addition)
        } catch {
            note = nil
            failure = error.localizedDescription
        }
    }

    private func applyUpdate(_ item: AskWorkflowGallery.Item) {
        do {
            try store.applyUpdate(item)
            failure = nil
            note = L("ask.workflow.gallery.updatedNote", item.name, item.version)
            updating = nil
            selected = item.id
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// An example's icon on its color.
struct AskWorkflowGalleryTile: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    var item: AskWorkflowGallery.Item
    var size: CGFloat

    var body: some View {
        Image(systemName: item.symbol).font(.system(.body, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Self.color(item),
                in: RoundedRectangle(
                    cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle),
                    style: .continuous
                )
            )
    }

    static func color(_ item: AskWorkflowGallery.Item) -> Color {
        switch item.color {
        case "orange": .orange
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "gray": .gray
        case "pink": .pink
        case "teal": .teal
        case "indigo": .indigo
        default: TypefluxColor.accent.color
        }
    }
}

/// A small colored label: "Network", "Added", "Copy to clipboard".
struct AskWorkflowGalleryTag: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    var text: String
    var color: Color

    var body: some View {
        Text(text).font(.system(.subheadline, weight: .medium)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 21)
            .background(
                color.opacity(0.14),
                in: RoundedRectangle(
                    cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle),
                    style: .continuous
                )
            )
    }
}

/// Settings' empty state (§1.1): the first examples, each one click from being added,
/// and the way to the whole gallery.
struct AskWorkflowGalleryStarter: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var store: AskWorkflowStore
    var gallery: AskWorkflowGallery
    var builtIn: [AskKeyword]
    var browse: () -> Void
    /// Opens an added example in the editor.
    var open: (String) -> Void
    @State private var failure: String?

    static let count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ask.workflow.gallery.emptyTitle")).font(.system(.body, weight: .semibold))
                .foregroundStyle(TypefluxColor.label.color)
            Text(L("ask.workflow.gallery.emptyHint")).font(.system(.callout))
                .foregroundStyle(TypefluxColor.secondaryLabel.color).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                ForEach(gallery.items.prefix(Self.count)) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            AskWorkflowGalleryTile(item: item, size: 24)
                            Text(item.name).font(.system(.body, weight: .semibold)).lineLimit(1)
                        }
                        Text(item.summary).font(.system(.subheadline))
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                        HStack(spacing: 5) {
                            ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0) }
                            Spacer(minLength: 4)
                            if let installed = store.installed(item) {
                                Button(L("ask.workflow.editor.edit")) { open(installed.id) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            } else {
                                Button(L("ask.workflow.gallery.add")) { add(item) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .accessibilityIdentifier("ask.workflow.gallery.starter.add." + item.id)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(
                        TypefluxColor.contentBackground.color,
                        in: RoundedRectangle(
                            cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                            style: .continuous
                        )
                    )
                    .overlay(RoundedRectangle(
                        cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                        style: .continuous
                    )
                    .strokeBorder(TypefluxColor.separator.color))
                }
            }
            HStack {
                Button(L("ask.workflow.gallery.browseAll", gallery.items.count), action: browse)
                    .buttonStyle(.borderless)
                if let failure {
                    Text(failure).font(.system(.subheadline)).foregroundStyle(TypefluxColor.danger.color)
                }
            }
            .font(.system(.callout))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func add(_ item: AskWorkflowGallery.Item) {
        do {
            let addition = try store.add(item, builtIn: builtIn)
            failure = nil
            open(addition.workflow.id)
        } catch {
            failure = error.localizedDescription
        }
    }
}
