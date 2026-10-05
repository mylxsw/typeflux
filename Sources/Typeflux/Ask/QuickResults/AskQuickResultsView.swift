import SwiftUI

/// The launcher's quick results in place of its starting points: the
/// calculation with its expression and large value and a few other spellings
/// that copy on their own, or the applications to open; then the way back to
/// the AI. Each kind of result starts with a small heading, so the list reads
/// as search results; the keyboard hint for the highlighted row sits in the bottom bar.
struct AskQuickResultsView: View {
    var results: AskQuickResults
    /// The launcher's text, which "Ask AI" sends as it is.
    var question: String
    /// Height held while typing; rows stay at the top.
    var minimumHeight: CGFloat = 0
    /// Runs a row. `close` is true for Return and for the calculation row.
    var onRun: (AskQuickResults.Row, _ close: Bool) -> Void
    var onHighlight: (Int) -> Void

    @State private var copied: Int?
    @State private var copiedReset: Task<Void, Never>?

    static let calculationHeight: CGFloat = 66
    static let formatHeight: CGFloat = 32
    static let askHeight: CGFloat = 42
    static let appHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let sectionHeight: CGFloat = 20

    enum Section: Equatable {
        case calculation, apps, ai

        var title: String {
            switch self {
            case .calculation: L("ask.quick.section.calculation")
            case .apps: L("ask.quick.section.apps")
            case .ai: L("ask.quick.section.ai")
            }
        }
    }

    static func section(of row: AskQuickResults.Row) -> Section {
        switch row {
        case .calculation, .format: .calculation
        case .app: .apps
        case .askAI: .ai
        }
    }

    /// The heading shown above the row at `index`: where a new kind of result begins.
    static func sectionStart(at index: Int, in rows: [AskQuickResults.Row]) -> Section? {
        guard rows.indices.contains(index) else { return nil }
        let section = section(of: rows[index])
        return index == 0 || Self.section(of: rows[index - 1]) != section ? section : nil
    }

    /// Everything this list adds to the launcher card.
    static func height(for results: AskQuickResults) -> CGFloat {
        let rows = results.rows
        let content = rows.reduce(CGFloat(0)) { total, row in
            switch row {
            case .calculation: total + calculationHeight
            case .format: total + formatHeight
            case .app: total + appHeight
            case .askAI: total + askHeight
            }
        }
        let sections = CGFloat(rows.indices.filter { sectionStart(at: $0, in: rows) != nil }.count)
        return 1 + listPadding * 2 + content + CGFloat(max(0, rows.count - 1)) * rowSpacing
            + sections * (sectionHeight + rowSpacing)
    }

    /// Return copies a calculation, opens an application, or sends to the AI.
    static func hint(for results: AskQuickResults) -> String {
        switch results.highlightedRow {
        case .askAI: L("ask.launcher.hint")
        case .app: L("ask.quick.hint.app")
        case .calculation, .format: L("ask.quick.hint")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(results.rows.enumerated()), id: \.offset) { index, row in
                    if let section = Self.sectionStart(at: index, in: results.rows) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: Self.sectionHeight, alignment: .bottom)
                            .accessibilityAddTraits(.isHeader)
                    }
                    content(row, index: index, highlighted: index == results.highlighted)
                        .onHover { if $0 { onHighlight(index) } }
                }
            }
            .padding(Self.listPadding)
            Spacer(minLength: 0)
        }
        .frame(height: max(minimumHeight, Self.height(for: results)), alignment: .top)
        .onDisappear { copiedReset?.cancel() }
    }

    @ViewBuilder private func content(_ row: AskQuickResults.Row, index: Int, highlighted: Bool) -> some View {
        switch row {
        case .calculation: calculationRow(highlighted: highlighted)
        case let .format(formatIndex): formatRow(results.formats[formatIndex], index: index, highlighted: highlighted)
        case let .app(appIndex): appRow(results.apps[appIndex].entry, row: row, highlighted: highlighted)
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
    private func appRow(_ app: AskAppEntry, row: AskQuickResults.Row, highlighted: Bool) -> some View {
        Button { onRun(row, true) } label: {
            HStack(spacing: 12) {
                Image(nsImage: AskAppIcon.image(for: app.url))
                    .resizable().interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(app.name).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(Self.location(of: app.url)).font(.system(size: 11.5))
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
                if highlighted, results.appsLead, row == results.rows.first {
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
        .accessibilityIdentifier("ask.quick.app")
    }

    /// "/Applications", "~/Applications/Chrome Apps" or "System": where the application is installed.
    static func location(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        if folder.hasPrefix("/System/") { return L("ask.quick.app.system") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
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
