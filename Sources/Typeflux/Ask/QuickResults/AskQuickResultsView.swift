import QuickLookThumbnailing
import SwiftUI

/// The launcher's quick results in place of its starting points: the
/// calculation with its expression and large value and a few other spellings
/// that copy on their own, or the applications, settings, files and folders to
/// open; then the way back to the AI. Each kind of result starts with a small
/// heading, so the list reads as search results; the keyboard hint for the
/// highlighted row sits in the bottom bar.
struct AskQuickResultsView: View {
    var results: AskQuickResults
    /// The launcher's text, which "Ask AI" sends as it is.
    var question: String
    /// Height held while typing; rows stay at the top.
    var minimumHeight: CGFloat = 0
    /// The highlighted file's actions, open with →.
    var actions: AskQuickActionPanel?
    var thumbnails = true
    /// Runs a row. `close` is true for Return and for the calculation row.
    var onRun: (AskQuickResults.Row, _ close: Bool) -> Void
    var onHighlight: (Int) -> Void
    var onAction: (AskQuickAction) -> Void = { _ in }

    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)
    @State private var copied: Int?
    @State private var copiedReset: Task<Void, Never>?

    static let calculationHeight: CGFloat = 66
    static let formatHeight: CGFloat = 32
    static let askHeight: CGFloat = 42
    static let appHeight: CGFloat = 42
    static let fileHeight: CGFloat = 42
    static let moreHeight: CGFloat = 30
    static let noticeHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let sectionHeight: CGFloat = 20
    /// Taller lists scroll; the launcher does not grow past this for results.
    static let maximumHeight: CGFloat = 430

    enum Section: Equatable {
        case calculation, best, apps, panes, files, folders, ai

        var title: String {
            switch self {
            case .calculation: L("ask.quick.section.calculation")
            case .best: L("ask.quick.section.best")
            case .apps: L("ask.quick.section.apps")
            case .panes: L("ask.quick.section.panes")
            case .files: L("ask.quick.section.files")
            case .folders: L("ask.quick.section.folders")
            case .ai: L("ask.quick.section.ai")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: Self.contentHeight(for: results) > Self.maximumHeight) {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(results.rows.map { (id: results.identity(of: $0), row: $0) }, id: \.id) { item in
                            let row = item.row
                            let index = results.rows.firstIndex(of: row) ?? 0
                            if let section = Self.sectionStart(at: index, in: results.rows, results: results) {
                                sectionTitle(section)
                            }
                            content(row, index: index, highlighted: index == results.highlighted)
                                .onContinuousHover { phase in
                                    if case .active = phase, actions == nil, pointer.moved(to: NSEvent.mouseLocation) {
                                        onHighlight(index)
                                    }
                                }
                                .id(item.id)
                        }
                        if let notice = results.notice { noticeRow(notice) }
                    }
                    .padding(Self.listPadding)
                }
                .scrollDisabled(Self.contentHeight(for: results) <= Self.maximumHeight)
                .onChange(of: results.highlighted) { index in proxy.scrollTo(results.identity(of: results.rows[index])) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: max(minimumHeight, Self.height(for: results)), alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let actions {
                AskQuickActionPanelView(panel: actions, onAction: onAction).padding(.top, 8).padding(.trailing, 14)
            }
        }
        .onAppear { pointer.position = NSEvent.mouseLocation }
        .onDisappear { copiedReset?.cancel() }
    }

    private func sectionTitle(_ section: Section) -> some View {
        Text(section.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Self.sectionHeight, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func content(_ row: AskQuickResults.Row, index: Int, highlighted: Bool) -> some View {
        switch row {
        case .calculation: calculationRow(highlighted: highlighted)
        case let .format(formatIndex): formatRow(results.formats[formatIndex], index: index, highlighted: highlighted)
        case let .app(appIndex): appRow(results.apps[appIndex], row: row, highlighted: highlighted)
        case let .pane(paneIndex): appRow(results.panes[paneIndex], row: row, highlighted: highlighted)
        case let .file(fileIndex): fileRow(results.files[fileIndex], row: row, highlighted: highlighted)
        case .showAllFiles: moreRow(highlighted: highlighted)
        case .askAI: askRow(highlighted: highlighted)
        }
    }

    @ViewBuilder private func calculationRow(highlighted: Bool) -> some View {
        if let calculation = results.calculation {
            calculationRow(calculation, highlighted: highlighted)
        }
    }

    private func calculationRow(_ calculation: AskCalculation, highlighted: Bool) -> some View {
        let expression = results.pendingExpression.map { $0 + " …" } ?? calculation.expression
        return Button { onRun(.calculation, true) } label: {
            HStack(spacing: 12) {
                tile("equal", tint: AskTheme.accent)
                Text(L("ask.quick.calculator")).font(.system(size: 13.5))
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
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .accessibilityLabel(L("ask.quick.calculator"))
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
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Self.marked(file.name, file.highlights).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Text(AskLauncherSearchSettings.abbreviate(file.folder)).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(highlighted ? L("ask.quick.file.actions") : Self.relative(file.modified))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: Self.fileHeight)
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .frame(width: 72, alignment: .leading)
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
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(format.value)
        .accessibilityLabel(format.kind.title)
        .accessibilityValue(format.value)
        .accessibilityHint(L("ask.quick.copy"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func askRow(highlighted: Bool) -> some View {
        Button { onRun(.askAI, true) } label: {
            HStack(spacing: 12) {
                tile("sparkles", tint: AskTheme.accent)
                Text(L("ask.quick.askAI")).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text("“" + question + "”").font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("⌘↩").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.askHeight)
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ask.quick.askAI"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("ask.quick.askAI")
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
