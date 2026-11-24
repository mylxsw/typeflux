// swiftlint:disable type_body_length
import SwiftUI

/// The context budget as a ring plus one percentage, sized to live inside the
/// composer footer. It replaced a full-width row under the composer that spent
/// a whole line restating what the panel already explains in detail.
struct AskContextUsageButton: View {
    /// Whole percent, with any non-empty context shown as at least 1%.
    static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        let value = Int((min(1, max(0, fraction)) * 100).rounded())
        return "\(fraction > 0 ? max(1, value) : 0)%"
    }

    let context: AskContextUsage
    var action: () -> Void
    @State private var hovering = false

    private var fraction: Double { min(1, max(0, context.fraction ?? 0)) }
    private var tint: Color { context.isHigh ? StudioTheme.warning : AskTheme.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(AskTheme.border, lineWidth: 2.5)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(Self.percentText(context.fraction))
                    .font(.system(size: 12)).monospacedDigit()
            }
            .foregroundStyle(hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: AskMetrics.composerControlHeight)
            .background(hovering ? AskTheme.hoverFill : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(summary)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("ask.usage.contextButton")
    }

    private var summary: String {
        L("ask.usage.context") + " ≈" + AccountUsageDisplayFormatter.count(Int64(context.inputTokens))
            + " · " + L("ask.usage.contextHelp")
    }
}

struct AskUsagePanel: View {
    @ObservedObject var model: AskConversationModel
    var compact = false
    var focusCloseOnAppear = false
    /// Shown as a drawer over the conversation rather than beside it.
    var floating = false
    @Binding var runId: String?
    var close: () -> Void
    @StateObject private var details = AskUsageDetails()
    private var items: [AskUsageInvocation] { details.items }
    private var cursor: Int64? { details.cursor }
    private var loading: Bool { details.loading }
    private var loadError: Bool { details.loadError }
    @FocusState private var closeFocused: Bool

    private var usage: AskConversationUsage? { model.selected?.usage }
    private var local: Bool { model.selectedId.map(model.isLocal) ?? false }
    private var totals: AskUsageTotals? { runId.flatMap { usage?.runs[$0] } ?? (runId == nil ? usage?.total : nil) }
    private var scopeKey: String { "\(model.owner)/\(model.selectedId ?? "")/\(runId ?? "all")" }
    private var loadKey: String { "\(scopeKey)/\(usage?.version ?? 0)/\(model.hasUsageRecords)" }

    @State private var expandedCall: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("ask.usage.title")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(focusCloseOnAppear ? .cancelAction : nil)
                .focused($closeFocused)
                .accessibilityLabel(L("ask.usage.close"))
                .accessibilityIdentifier("ask.workspace.drawer.close")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            // The flush panel spans the whole title row, so its rule lines up
            // with the one under the conversation's title.
            .frame(height: AskMetrics.titleBarRowHeight - 1)
            .zIndex(1)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            ScrollView {
                // Two questions, two cards: "does the next message still fit?"
                // and "what did this cost?".
                VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    if let context = model.usageContext, let capacity = context.capacity, let remaining = context.remaining {
                        contextCard(context, capacity: capacity, remaining: remaining)
                    }
                    if let budget = model.selected?.run?.budget { AskBudgetView(budget: budget) }
                    if scopeOptions.count > 1 {
                        AskSegmentedControl(options: scopeOptions, selection: $runId)
                            .padding(.top, 4)
                    }
                    if model.hasUsageRecords, let totals {
                        totalsCard(totals)
                    } else if !model.hasUsageRecords || (!loading && !loadError && items.isEmpty) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "chart.pie").accessibilityHidden(true)
                            Text(L("ask.usage.empty"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(L("ask.usage.emptyHelp")).font(.system(size: 11))
                        }
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("ask.usage.empty"))
                        .accessibilityHint(L("ask.usage.emptyHelp"))
                        .accessibilityIdentifier("ask.usage.empty")
                    } else if !loading {
                        Text(L("ask.usage.unavailable")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    if usage?.historicalGap == true { help("ask.usage.historicalGap") }
                    callsSection
                }
                .padding(compact ? 12 : 16)
            }
            // The native scroll view can otherwise receive clicks above the visible viewport.
            .clipped()
            .contentShape(Rectangle())
        }
        // The sidebar's twin on the trailing side: a full-height column flush
        // with the window edge.
        .frame(width: AskMetrics.usagePanelWidth)
        .askSidePanel(edge: .trailing, floating: floating)
        .task(id: loadKey) {
            await load(reset: true)
            for delay in [2, 4, 8, 16, 30, 30] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard (usage?.total.pending ?? 0) > 0 else { return }
                await load(reset: true)
            }
        }
        .onExitCommand(perform: close)
        .onAppear { if focusCloseOnAppear { closeFocused = true } }
        .onChange(of: focusCloseOnAppear) { if $0 { closeFocused = true } }
    }

    /// "This turn" only exists once the conversation has a run to scope to.
    private var scopeOptions: [(value: String?, title: String)] {
        var options: [(value: String?, title: String)] = []
        if let current = runId ?? model.selected?.run?.id {
            options.append((value: current, title: L("ask.usage.round")))
        }
        options.append((value: nil, title: L("ask.usage.conversation")))
        return options
    }

    private func contextCard(_ context: AskContextUsage, capacity: Int, remaining: Int) -> some View {
        let percent = AskContextUsageButton.percentText(context.fraction)
        return card {
            cardLabel(L("ask.usage.conversationContext")) {
                Text(L("ask.usage.contextLimit", AccountUsageDisplayFormatter.count(Int64(capacity))))
                    .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textSecondary)
            }
            Text(L("ask.usage.contextPercentUsed", percent))
                .font(.system(size: compact ? 19 : 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(context.isHigh ? StudioTheme.warning : StudioTheme.textPrimary)
            budgetBar(context)
            HStack {
                Text(L("ask.usage.contextUsed", AccountUsageDisplayFormatter.count(Int64(max(0, context.inputTokens)))))
                Spacer()
                Text(L("ask.usage.contextFree", AccountUsageDisplayFormatter.count(Int64(remaining))))
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(StudioTheme.textSecondary)
            if context.summarized { help("ask.usage.summarized") }
            if context.isHigh { help("ask.usage.highHelp") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.usage.contextCard")
        .help(L("ask.usage.contextHelp"))
    }

    private func totalsCard(_ totals: AskUsageTotals) -> some View {
        card {
            cardLabel(L(!local && totals.pending > 0 ? "ask.usage.recordedSpend" : "ask.usage.spent")) {
                Text(L(runId == nil ? "ask.usage.conversation" : "ask.usage.round"))
                    .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            figure(local ? totals.tokenText(totals.totalTokens) : totals.creditsText,
                   unit: local ? "tokens" : "credits")
            if local { help("ask.usage.localHelp") }
            else if let key = totals.statusKey { help(key) }
            VStack(spacing: 0) {
                detail("ask.usage.input", totals.tokenText(totals.inputTokens))
                rule
                if let cached = totals.cachedInputTokens, cached > 0 {
                    detail("ask.usage.cachedInput", totals.tokenText(cached))
                    rule
                }
                detail("ask.usage.output", totals.tokenText(totals.outputTokens))
                rule
                detail("ask.usage.total", totals.tokenText(totals.totalTokens))
            }
            .padding(.top, 2)
            if totals.estimated > 0 { help("ask.usage.estimated") }
        }
    }

    /// Individual model calls, each a row that expands in place.
    @ViewBuilder private var callsSection: some View {
        if !items.isEmpty || loading || loadError || cursor != nil {
            Text(L("ask.usage.calls")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rule }
                    invocation(item)
                }
                if loading && items.isEmpty { ProgressView().controlSize(.small).padding(10) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
            if loadError {
                Text(L("ask.usage.loadError")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                Button { Task { await load(reset: false) } } label: {
                    Label(L("ask.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityIdentifier("ask.usage.retry")
            } else if cursor != nil {
                Button(L("ask.usage.more")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(AskTheme.accentText)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 9 : 13)
            .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
    }

    private func cardLabel<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.textTertiary)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// The card's one large number, with its unit set small beside it.
    private func figure(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: compact ? 21 : 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(StudioTheme.textPrimary)
            Text(verbatim: unit).font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var rule: some View { Rectangle().fill(AskTheme.separator).frame(height: 1) }

    private func budgetBar(_ context: AskContextUsage) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(context.isHigh ? StudioTheme.warning : AskTheme.accent)
                    .frame(width: geometry.size.width * min(1, max(0, context.fraction ?? 0)))
                Rectangle().fill(AskTheme.segmentTrack)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private func invocation(_ item: AskUsageInvocation) -> some View {
        let expanded = expandedCall == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expandedCall = expanded ? nil : item.id }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(L(item.purpose.hasPrefix("image_") ? "imagegen.title"
                           : item.purpose == "summary" ? "ask.usage.summary" : "ask.usage.inference"))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text(item.tokenUsageText).foregroundStyle(StudioTheme.textPrimary).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.modelLibrary.name(for: item.modelRef))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.textSecondary)
                        .padding(.bottom, 4)
                    if let tokens = item.tokens {
                        detail("ask.usage.input", String(tokens.promptTokens))
                        if let cached = tokens.cachedTokens, cached > 0 {
                            detail("ask.usage.cachedInput", String(cached))
                        }
                        detail("ask.usage.output", String(tokens.completionTokens))
                        detail("ask.usage.total", String(tokens.totalTokens))
                    } else if !item.purpose.hasPrefix("image_") { help("ask.usage.unavailable") }
                }
                .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(L(title)).foregroundStyle(StudioTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(StudioTheme.textPrimary)
        }
        .font(.system(size: 12))
        .padding(.vertical, 7)
    }

    private func help(_ key: String) -> some View { Text(L(key)).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true) }

    @MainActor private func load(reset: Bool) async {
        let id = model.selectedId
        let scope = runId
        await details.load(key: scopeKey, hasRecords: id != nil && model.hasUsageRecords, reset: reset) { cursor in
            guard let id else { return AskUsagePage(items: [], nextCursor: nil) }
            return try await model.usagePage(id: id, runId: scope, cursor: cursor)
        }
    }
}
