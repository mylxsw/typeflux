import SwiftUI

/// The launcher's quick results in place of its starting points: the
/// calculation with its expression and large value, a few other spellings that
/// copy on their own, the way back to the AI, and the keyboard hint.
struct AskQuickResultsView: View {
    var results: AskQuickResults
    /// The launcher's text, which "Ask AI" sends as it is.
    var question: String
    /// Runs a row. `close` is true for Return and for the calculation row.
    var onRun: (AskQuickResults.Row, _ close: Bool) -> Void
    var onHighlight: (Int) -> Void

    @State private var copied: Int?
    @State private var copiedReset: Task<Void, Never>?

    static let calculationHeight: CGFloat = 66
    static let formatHeight: CGFloat = 32
    static let askHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let hintHeight: CGFloat = 24

    /// Everything this list adds to the launcher card.
    static func height(for results: AskQuickResults) -> CGFloat {
        let formats = CGFloat(results.formats.count)
        return 1 + listPadding * 2 + calculationHeight + formats * formatHeight + askHeight
            + (formats + 1) * rowSpacing + hintHeight
    }

    /// Return copies unless the highlight is on "Ask AI".
    static func hint(for results: AskQuickResults) -> String {
        L(results.highlightedRow == .askAI ? "ask.launcher.hint" : "ask.quick.hint")
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(results.rows.enumerated()), id: \.offset) { index, row in
                    content(row, index: index, highlighted: index == results.highlighted)
                        .onHover { if $0 { onHighlight(index) } }
                }
            }
            .padding(Self.listPadding)
            Text(Self.hint(for: results))
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .frame(height: Self.hintHeight, alignment: .top)
                .accessibilityHidden(true)
        }
        .onDisappear { copiedReset?.cancel() }
    }

    @ViewBuilder private func content(_ row: AskQuickResults.Row, index: Int, highlighted: Bool) -> some View {
        switch row {
        case .calculation: calculationRow(highlighted: highlighted)
        case let .format(formatIndex): formatRow(results.formats[formatIndex], index: index, highlighted: highlighted)
        case .askAI: askRow(highlighted: highlighted)
        }
    }

    private func calculationRow(highlighted: Bool) -> some View {
        let calculation = results.calculation
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
        switch results.calculation.outcome {
        case let .success(number): results.calculation.expression + " = " + number.displayText
        case let .failure(error): error.message
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
