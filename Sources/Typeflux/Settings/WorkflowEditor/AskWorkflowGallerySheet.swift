// swiftlint:disable file_length
import SwiftUI

/// The gallery (§1.2): categories and search on the left, example cards on the right;
/// a card opens its detail page, and an added example with a newer version opens the
/// differences before anything is overwritten.
struct AskWorkflowGallerySheet: View {
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
            Rectangle().fill(ModelVisualStyle.border).frame(width: 1)
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
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(12)
                .accessibilityLabel(L("ask.workflow.editor.close"))
            }
        }
        .frame(width: 980, height: 640)
        .background(StudioTheme.windowBackground)
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
            Text(L("ask.workflow.gallery.title")).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("ask.workflow.gallery.subtitle")).font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.workflow.gallery.search"), text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("ask.workflow.gallery.search")
            }
            .font(.system(size: 12.5)).padding(.horizontal, 9).frame(height: 30)
            .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
                Label(note, systemImage: "checkmark.circle.fill").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.success).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.workflow.gallery.note")
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StudioTheme.surfaceMuted)
    }

    private func categoryRow(_ value: AskWorkflowGallery.Category?, title: String, count: Int) -> some View {
        let isSelected = category == value && selected == nil && updating == nil
        return Button {
            category = value
            selected = nil
            updating = nil
        } label: {
            HStack {
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
                Text("\(count)").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 12).frame(height: 34)
            .background(isSelected ? StudioTheme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                Text(L("ask.workflow.gallery.noResults")).font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.top, 14)
            }
        }
    }

    private func card(_ item: AskWorkflowGallery.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AskWorkflowGalleryTile(item: item, size: 30)
                Text(item.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            Text(item.summary).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0).fixedSize() }
                Text(item.runtime.title).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize()
                tags(item)
                Spacer(minLength: 4)
                if store.installed(item) == nil || store.hasUpdate(item) {
                    cardButton(item).fixedSize().layoutPriority(1)
                }
            }
            if store.installed(item) != nil, !store.hasUpdate(item) {
                cardButton(item).fixedSize()
            }
        }
        .padding(16).frame(height: 168)
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { selected = item.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.workflow.gallery.card." + item.id)
    }

    /// "Network" for examples that reach the network, "Needs Node" when its runtime is missing.
    @ViewBuilder private func tags(_ item: AskWorkflowGallery.Item) -> some View {
        if !item.hosts.isEmpty {
            AskWorkflowGalleryTag(text: L("ask.workflow.gallery.network"), color: .orange).fixedSize()
        }
        if missing?.contains(item.runtime) == true {
            AskWorkflowGalleryTag(text: L("ask.workflow.gallery.needs", item.runtime.title), color: StudioTheme.warning)
                .fixedSize()
                .help(L("ask.workflow.gallery.install." + item.runtime.rawValue))
        }
    }

    @ViewBuilder private func cardButton(_ item: AskWorkflowGallery.Item) -> some View {
        if store.hasUpdate(item) {
            Button(L("ask.workflow.gallery.viewUpdate")) { updating = item.id }
                .buttonStyle(AskWorkflowActionStyle(small: true))
        } else if store.installed(item) != nil {
            AskWorkflowGalleryTag(text: L("ask.workflow.gallery.added"), color: StudioTheme.success)
        } else {
            Button(L("ask.workflow.gallery.add")) { add(item) }
                .buttonStyle(AskWorkflowActionStyle(small: true))
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
                Text("‹ " + L("ask.workflow.gallery.title")).font(.system(size: 12.5)).foregroundStyle(AskTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.workflow.gallery.back")
            HStack(alignment: .top, spacing: 14) {
                AskWorkflowGalleryTile(item: item, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                    Text(item.summary).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
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
                AskWorkflowGalleryTag(text: L("ask.workflow.gallery.added"), color: StudioTheme.success)
                if store.hasUpdate(item) {
                    Button(L("ask.workflow.gallery.viewUpdate")) { updating = item.id }
                        .buttonStyle(AskWorkflowActionStyle())
                }
                Button(L("ask.workflow.gallery.openInEditor")) { open(installed.id) }
                    .buttonStyle(AskWorkflowActionStyle())
                    .accessibilityIdentifier("ask.workflow.gallery.open")
            } else {
                Button(L("ask.workflow.gallery.addToMine")) { add(item) }
                    .buttonStyle(AskWorkflowActionStyle(kind: .primary))
                    .accessibilityIdentifier("ask.workflow.gallery.addDetail")
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(StudioTheme.textSecondary)
            content()
        }
    }

    private func facts(_ item: AskWorkflowGallery.Item) -> some View {
        let rows: [(String, AnyView)] = [
            (L("ask.workflow.trust.keywords"), AnyView(AgentFlowLayout(spacing: 5) {
                ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0) }
                Text(L("ask.workflow.gallery.renameHint", (item.keywords.first ?? "fx") + "2"))
                    .foregroundStyle(StudioTheme.textSecondary)
            })),
            (L("ask.workflow.gallery.runtime"), AnyView(Text(runtimeText(item)))),
            (L("ask.workflow.gallery.does"), AnyView(AgentFlowLayout(spacing: 5) {
                ForEach(item.hosts, id: \.self) { host in
                    AskWorkflowGalleryTag(text: L("ask.workflow.gallery.visits", host), color: .orange)
                }
                ForEach(Array(Self.actions(item).enumerated()), id: \.offset) { _, title in
                    AskWorkflowGalleryTag(text: title, color: StudioTheme.textSecondary)
                }
                if item.hosts.isEmpty, Self.actions(item).isEmpty {
                    Text(L("ask.workflow.gallery.showsOnly"))
                }
            })),
            (L("ask.workflow.gallery.demonstrates"), AnyView(Text(item.demonstrates))),
            (L("ask.workflow.trust.files"), AnyView(Text(item.files().keys.filter { $0 != AskWorkflowManifest.fileName }
                    .sorted().joined(separator: " · ")).font(.system(size: 12, design: .monospaced))))
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0).foregroundStyle(StudioTheme.textTertiary).frame(width: 76, alignment: .leading)
                    row.1.foregroundStyle(StudioTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12.5)).padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
                    Text(line.description).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
            Text(Self.preview(text)).font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(StudioTheme.textPrimary).textSelection(.enabled)
                .fixedSize().padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
                Text("‹ " + item.name).font(.system(size: 12.5)).foregroundStyle(AskTheme.accent)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(L("ask.workflow.gallery.update.title", item.name, version, item.version))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Button(L("ask.workflow.cancel")) { updating = nil }
                    .buttonStyle(AskWorkflowActionStyle())
                Button(L("ask.workflow.gallery.update.apply")) { applyUpdate(item) }
                    .buttonStyle(AskWorkflowActionStyle(kind: .primary))
                    .accessibilityIdentifier("ask.workflow.gallery.update.apply")
            }
            .padding(.trailing, 30)
            Text(update.userModified.isEmpty ? L("ask.workflow.gallery.update.hint")
                : L("ask.workflow.gallery.update.modified", update.userModified.sorted().joined(separator: ", ")))
                .font(.system(size: 12.5))
                .foregroundStyle(update.userModified.isEmpty ? StudioTheme.textSecondary : StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            AskWorkflowDiffView(old: update.current, new: update.updated, labels: (
                L("ask.workflow.gallery.update.mine"), L("ask.workflow.gallery.update.new")
            ), suffix: L("ask.workflow.editor.diff.diffSuffix"), marked: update.userModified,
            markHint: L("ask.workflow.gallery.update.markHint")) { EmptyView() }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
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
    var item: AskWorkflowGallery.Item
    var size: CGFloat

    var body: some View {
        Image(systemName: item.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(item), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
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
        default: AskWorkflowEditorStyle.tileColor(for: item.id)
        }
    }
}

/// A small colored label: "Network", "Added", "Copy to clipboard".
struct AskWorkflowGalleryTag: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 21)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Settings' empty state (§1.1): the first examples, each one click from being added,
/// and the way to the whole gallery.
struct AskWorkflowGalleryStarter: View {
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
            Text(L("ask.workflow.gallery.emptyTitle")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("ask.workflow.gallery.emptyHint")).font(.system(size: 12))
                .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                ForEach(gallery.items.prefix(Self.count)) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            AskWorkflowGalleryTile(item: item, size: 24)
                            Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        Text(item.summary).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                        HStack(spacing: 5) {
                            ForEach(item.keywords, id: \.self) { AskWorkflowChip(text: $0) }
                            Spacer(minLength: 4)
                            if let installed = store.installed(item) {
                                Button(L("ask.workflow.editor.edit")) { open(installed.id) }
                                    .buttonStyle(AskWorkflowActionStyle(small: true))
                            } else {
                                Button(L("ask.workflow.gallery.add")) { add(item) }
                                    .buttonStyle(AskWorkflowActionStyle(small: true))
                                    .accessibilityIdentifier("ask.workflow.gallery.starter.add." + item.id)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border))
                }
            }
            HStack {
                Button(L("ask.workflow.gallery.browseAll", gallery.items.count), action: browse)
                    .buttonStyle(.borderless)
                if let failure {
                    Text(failure).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
                }
            }
            .font(.system(size: 12.5))
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
