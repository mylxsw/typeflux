import SwiftUI

/// The launcher's quick results in place of its starting points: the
/// calculation with its expression and large value and a few other spellings
/// that copy on their own, or the applications, settings, files and folders to
/// open. The header owns the AI action. Each kind of result starts with a small
/// heading, so the list reads as search results; the keyboard hint for the
/// highlighted row sits in the bottom bar.
struct AskQuickResultsView: View {
    var results: AskQuickResults
    /// The launcher's text, which "Ask AI" sends as it is.
    var question: String
    /// Height held while typing; rows stay at the top.
    var minimumHeight: CGFloat = 0
    /// Actual space during native resizing, shared with the bottom toolbar.
    var viewportHeight: CGFloat?
    /// The highlighted file's actions, open with → or a context click.
    var actions: AskQuickActionPanel?
    var thumbnails = true
    /// Runs a row. `close` is true for Return and for the calculation row.
    var onRun: (AskQuickResults.Row, _ close: Bool) -> Void
    var onHighlight: (Int) -> Void
    var onAction: (AskQuickAction) -> Void = { _ in }
    var onShowFileActions: (AskFileHit) -> Void = { _ in }
    var calendarProvider: (any CalendarEventProviding)?

    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)
    /// The rows of the previous render: the highlight slides only between the same rows.
    @State private var highlightMemo = HighlightMemo()
    @Namespace private var highlightSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied: Int?
    @State private var copiedReset: Task<Void, Never>?

    static let calculationHeight: CGFloat = 66
    static let formatHeight: CGFloat = 32
    static let askHeight: CGFloat = 42
    static let appHeight: CGFloat = 42
    static let fileHeight: CGFloat = 42
    /// A content match adds its folder and page, then the matched passage.
    static let contentFileHeight: CGFloat = 62
    static let moreHeight: CGFloat = 30
    static let noticeHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let sectionHeight: CGFloat = 20
    /// Taller lists scroll; the launcher does not grow past this for results.
    static let maximumHeight: CGFloat = 430

    enum Section: Equatable {
        case calculation, best, features, apps, panes, files, folders, tabs, bookmarks, ai

        var title: String {
            switch self {
            case .calculation: L("ask.quick.section.calculation")
            case .best: L("ask.quick.section.best")
            case .tabs: L("ask.browser.tabs")
            case .bookmarks: L("ask.browser.bookmarks")
            case .features: L("ask.quick.section.features")
            case .apps: L("ask.quick.section.apps")
            case .panes: L("ask.quick.section.panes")
            case .files: L("ask.quick.section.files")
            case .folders: L("ask.quick.section.folders")
            case .ai: L("ask.quick.section.ai")
            }
        }
    }

    private struct ScrollPosition: Equatable {
        var rows: [String]
        var target: String
    }

    private static let topID = "quickResults.top"

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            if !results.listRows.isEmpty || results.notice != nil {
                let items = Self.listItems(for: results)
                let _ = highlightMemo.update(rows: items.map(\.id))
                let scrolls = Self.contentHeight(for: results) > visibleHeight
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: scrolls) {
                        // At most a few dozen rows: build them all once, so scrolling
                        // never creates rows or loads icons mid-gesture.
                        VStack(spacing: Self.rowSpacing) {
                            ForEach(items, id: \.id) { item in
                                // One identified block includes its heading. A changing
                                // heading must not leave the scroll anchor on a removed sibling.
                                VStack(spacing: Self.rowSpacing) {
                                    if let section = item.section {
                                        sectionTitle(section)
                                    }
                                    resultRow(item.row, index: item.index)
                                }
                                .id(item.id)
                            }
                            if let notice = results.notice { noticeRow(notice) }
                        }
                        .padding(.horizontal, Self.listPadding)
                        .padding(.top, Self.listPadding)
                        .padding(.bottom, Self.listPadding)
                        .id(Self.topID)
                    }
                    .scrollDisabled(!scrolls)
                    // SwiftUI may deliver the new value to an old render's closure.
                    // Carry both the target and list version in the new value itself.
                    .onChange(of: ScrollPosition(
                        rows: items.map(\.id),
                        target: results.chosen && results.highlightedRow != .askAI
                            ? results.identity(of: results.highlightedRow) : Self.topID
                    )) { position in
                        proxy.scrollTo(position.target, anchor: position.target == Self.topID ? .top : nil)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: visibleHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let actions {
                AskQuickActionPanelView(panel: actions, onAction: onAction).padding(.top, 8).padding(.trailing, 14)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear { pointer.position = NSEvent.mouseLocation }
        .onDisappear { copiedReset?.cancel() }
    }

    private func resultRow(_ row: AskQuickResults.Row, index: Int) -> some View {
        content(row, index: index, highlighted: index == results.highlighted)
            .modifier(AskLauncherNumberBadge(number: actions == nil ? AskLauncherNumberShortcuts.number(at: index) : nil))
            .onContinuousHover { phase in
                if case .active = phase, actions == nil, pointer.moved(to: NSEvent.mouseLocation) {
                    onHighlight(index)
                }
            }
    }

    private func sectionTitle(_ section: Section) -> some View {
        Text(section == .calculation && results.calculation?.isNumericInput == true
             ? L("ask.quick.numberConversions") : section.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Self.sectionHeight, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    private var visibleHeight: CGFloat { viewportHeight ?? max(minimumHeight, Self.height(for: results)) }

    @ViewBuilder private func content(_ row: AskQuickResults.Row, index: Int, highlighted: Bool) -> some View {
        switch row {
        case let .feature(featureIndex): featureRow(results.features[featureIndex], row: row, highlighted: highlighted)
        case let .browser(browserIndex): browserRow(results.browserEntries[browserIndex], row: row, highlighted: highlighted)
        case .calculation: calculationRow(highlighted: highlighted)
        case let .format(formatIndex): formatRow(results.formats[formatIndex], index: index, highlighted: highlighted)
        case let .app(appIndex): appRow(results.apps[appIndex], row: row, highlighted: highlighted)
        case let .pane(paneIndex): appRow(results.panes[paneIndex], row: row, highlighted: highlighted)
        case let .file(fileIndex): fileRow(results.files[fileIndex], row: row, highlighted: highlighted)
        case .showAllFiles: moreRow(highlighted: highlighted)
        case .askAI: EmptyView()
        }
    }

    private func browserRow(_ entry: AskBrowserSearchEntry, row: AskQuickResults.Row, highlighted: Bool) -> some View {
        return AskPluginItemRow(item: entry.item(settings: .init()), symbol: entry.kind == .tab ? "rectangle.on.rectangle" : "bookmark",
                               selected: highlighted, emphasized: true, height: Self.appHeight) { onRun(row, true) }
    }

    private func featureRow(_ entry: AskLauncherSearchEntry, row: AskQuickResults.Row, highlighted: Bool) -> some View {
        Button { onRun(row, true) } label: {
            HStack(spacing: 12) {
                tile(entry.symbol, tint: entry.keyword.pluginID == AskCalendarPlugin.id ? .red : AskTheme.accent)
                Text(entry.title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                if !entry.keyword.keyword.isEmpty {
                    Text(entry.keyword.keyword).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                Spacer(minLength: 8)
                if entry.keyword.pluginID == AskCalendarPlugin.id {
                    CalendarHintSummary(options: entry.keyword.options, provider: calendarProvider)
                } else {
                    Text(highlighted
                        ? L(entry.command == nil ? "ask.plugin.prefix.enter" : "ask.system.run") + " ↩" : entry.detail)
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).frame(height: Self.appHeight)
            .background { highlightShape(highlighted, cornerRadius: 14) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.keyword.keyword)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("ask.quick.feature")
    }

    @ViewBuilder private func calculationRow(highlighted: Bool) -> some View {
        if let calculation = results.calculation {
            calculationRow(calculation, highlighted: highlighted)
        }
    }

    private func calculationRow(_ calculation: AskCalculation, highlighted: Bool) -> some View {
        let expression = results.pendingExpression.map { $0 + " …" } ?? calculation.expression
        let title = L(calculation.isNumericInput ? "ask.quick.numberConversions" : "ask.quick.calculator")
        return Button { onRun(.calculation, true) } label: {
            HStack(spacing: 12) {
                tile(calculation.isNumericInput ? "number" : "equal", tint: AskTheme.accent)
                Text(title).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(expression).font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.head)
                    switch calculation.outcome {
                    case let .success(number):
                        Text(number.displayText).font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(results.stale ? StudioTheme.textTertiary : StudioTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    case let .failure(error):
                        Text(error.message).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(StudioTheme.danger)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.calculationHeight)
            .background { highlightShape(highlighted, cornerRadius: 16) }
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AskTheme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!results.isEnabled(.calculation))
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("ask.quick.calculation")
    }

    private var accessibilityValue: String {
        guard let calculation = results.calculation else { return "" }
        switch calculation.outcome {
        case let .success(number): return calculation.expression + " = " + number.displayText
        case let .failure(error): return error.message
        }
    }

    /// The application's icon and name, where it lives, and "Open" when highlighted.
    private func appRow(_ match: AskAppMatch, row: AskQuickResults.Row, highlighted: Bool) -> some View {
        let app = match.entry
        return Button { onRun(row, true) } label: {
            HStack(spacing: 12) {
                AskFileIconView(url: app.url, thumbnail: false)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Self.marked(app.name, match.highlights).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(app.kind == .settingsPane ? L("ask.quick.pane.location") : Self.location(of: app.url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if highlighted {
                    Text(L("ask.quick.app.open") + " ↩").font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.appHeight)
            .background { highlightShape(highlighted, cornerRadius: 14) }
            .overlay {
                if highlighted, results.best == row, row == results.rows.first {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AskTheme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .accessibilityHint(L("ask.quick.app.open"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier(app.kind == .settingsPane ? "ask.quick.pane" : "ask.quick.app")
    }

    /// A file or folder: its icon or thumbnail, name with the matched letters marked,
    /// the folder it is in, and when it changed (or what Return and → do, when highlighted).
    private func fileRow(_ file: AskFileHit, row: AskQuickResults.Row, highlighted: Bool) -> some View {
        Button { onRun(row, true) } label: {
            HStack(spacing: 12) {
                AskFileIconView(url: file.url, thumbnail: thumbnails && file.kind == .file, modified: file.modified)
                    .frame(width: 28, height: 28)
                if let evidence = file.evidence {
                    contentMatch(file, evidence: evidence, highlighted: highlighted)
                } else {
                    Self.marked(file.name, file.highlights).font(.system(size: 13.5))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    Text(AskLauncherSearchSettings.abbreviate(file.folder)).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    fileTrailing(file, highlighted: highlighted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: file.evidence == nil ? Self.fileHeight : Self.contentFileHeight)
            .background { highlightShape(highlighted, cornerRadius: 14) }
            .overlay {
                if highlighted, results.best == row, row == results.rows.first {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AskTheme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AskLauncherSearchSettings.abbreviate(file.path))
        .accessibilityLabel(file.name)
        .accessibilityValue(AskLauncherSearchSettings.abbreviate(file.folder))
        .accessibilityHint(L("ask.quick.app.open"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier(file.isFolder ? "ask.quick.folder" : "ask.quick.file")
        .overlay {
            AskQuickResultSecondaryClick { onShowFileActions(file) }
                .accessibilityHidden(true)
        }
    }

    private func moreRow(highlighted: Bool) -> some View {
        Button { onRun(.showAllFiles, false) } label: {
            HStack(spacing: 8) {
                Text(L("ask.quick.file.showAll")).font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 8)
                Text("⌘↓").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.leading, 50)
            .padding(.trailing, 10)
            .frame(height: Self.moreHeight)
            .background { highlightShape(highlighted, cornerRadius: 12) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("ask.quick.showAll")
    }

    @ViewBuilder private func noticeRow(_ notice: AskQuickResults.Notice) -> some View {
        switch notice {
        case let .indexing(found, progress):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 28)
                Text(L("ask.quick.file.indexing", found.formatted())).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress).frame(maxWidth: 120)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.noticeHeight)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ask.quick.indexing")
        }
    }

    private func formatRow(_ format: AskCalculatorFormat, index: Int, highlighted: Bool) -> some View {
        let done = copied == index
        return Button { copy(index) } label: {
            HStack(spacing: 10) {
                Text(format.kind.title).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: results.calculation?.isNumericInput == true ? 110 : 72, alignment: .leading)
                    .help(format.kind == .base64 ? L("ask.quick.format.base64.alphabet") : format.kind.title)
                Text(format.value).font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(results.stale ? StudioTheme.textTertiary : StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark" : "doc.on.doc").font(.system(size: 11.5))
                    .foregroundStyle(done ? StudioTheme.success : StudioTheme.textTertiary)
                    .frame(width: 24)
            }
            .padding(.leading, 50)
            .padding(.trailing, 10)
            .frame(height: Self.formatHeight)
            .background { highlightShape(highlighted, cornerRadius: 12) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(format.value)
        .accessibilityLabel(format.kind.title)
        .accessibilityValue(format.value)
        .accessibilityHint(L("ask.quick.copy"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    /// One highlight shape that moves from row to row. When only the highlight moves
    /// (arrow keys, the pointer) it glides to the new row; when the rows themselves
    /// change it simply appears on its row, so a new batch never animates.
    @ViewBuilder private func highlightShape(_ highlighted: Bool, cornerRadius: CGFloat) -> some View {
        let slides = highlightMemo.sameRows && !reduceMotion
        ZStack {
            if highlighted {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AskTheme.hoverFill)
                    .matchedGeometryEffect(id: "quickResults.highlight", in: highlightSpace)
            }
        }
        .transaction { transaction in
            // The launcher disables animations; the highlight opts back in for itself only.
            transaction.disablesAnimations = !slides
            transaction.animation = slides ? Self.highlightMotion : nil
        }
    }

    static let highlightMotion: Animation = .easeOut(duration: 0.12)

    /// Remembers the previous render's rows. A reference, so updating it in `body`
    /// never invalidates the view.
    final class HighlightMemo {
        private var rows: [String] = []
        private(set) var sameRows = false

        func update(rows next: [String]) {
            sameRows = rows == next
            rows = next
        }
    }

    private func tile(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Clicking a spelling copies it and keeps the launcher open, with a brief check mark.
    private func copy(_ index: Int) {
        onRun(results.rows[index], false)
        copied = index
        copiedReset?.cancel()
        copiedReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            copied = nil
        }
    }
}
