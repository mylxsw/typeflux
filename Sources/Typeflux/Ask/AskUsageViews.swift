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
    private var tint: Color { context.isHigh ? TypefluxColor.warning.color : TypefluxColor.accent.color }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(TypefluxColor.separator.color, lineWidth: 2.5)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(Self.percentText(context.fraction))
                    .font(.callout).monospacedDigit()
            }
            .foregroundStyle(hovering ? TypefluxColor.label.color : TypefluxColor.secondaryLabel.color)
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: AskMetrics.composerControlHeight)
            .background(hovering ? TypefluxColor.label.color.opacity(0.06) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(summary)
        .accessibilityLabel(summary)
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
    @ObservedObject private var auth = AuthState.shared
    @Environment(\.interfaceStyle) private var style
    @Binding var runId: String?
    var close: () -> Void
    @StateObject private var details: AskUsageDetails
    private var items: [AskUsageInvocation] { details.items }
    private var cursor: Int64? { details.cursor }
    private var loading: Bool { details.loading }
    private var loadError: Bool { details.loadError }
    @FocusState private var closeFocused: Bool

    @MainActor
    init(model: AskConversationModel, compact: Bool = false, focusCloseOnAppear: Bool = false,
         floating: Bool = false, runId: Binding<String?>, close: @escaping () -> Void,
         details: AskUsageDetails? = nil) {
        self.model = model
        self.compact = compact
        self.focusCloseOnAppear = focusCloseOnAppear
        self.floating = floating
        _runId = runId
        self.close = close
        _details = StateObject(wrappedValue: details ?? AskUsageDetails())
    }

    private var usage: AskConversationUsage? { model.selected?.usage }
    private var local: Bool { model.selectedId.map(model.isLocal) ?? false }
    private var totals: AskUsageTotals? { runId.flatMap { usage?.runs[$0] } ?? (runId == nil ? usage?.total : nil) }
    private var loadKey: String {
        "\(model.selectedId ?? "")/\(usage?.version ?? 0)/\(model.selected?.run?.id ?? "none")/\(runId ?? "all")" }

    @State private var expandedCall: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("ask.usage.title")).font(.body).fontWeight(.semibold)
                    .foregroundStyle(TypefluxColor.label.color)
                Spacer()
                TypefluxIconButton(L("ask.usage.close"), systemImage: "xmark", action: close)
                    .keyboardShortcut(focusCloseOnAppear ? .cancelAction : nil)
                    .focused($closeFocused)
                    .accessibilityLabel(L("ask.usage.close"))
                    .accessibilityIdentifier("ask.workspace.drawer.close")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            // Centred on the header pills' row, below the panel's own inset. A
            // flush classic panel spans the whole title row, so its rule lines
            // up with the one under the conversation's title.
            .frame(height: AskMetrics.titleBarRowHeight
                - (style.usesGlass ? AskMetrics.sidebarPanelInset * 2 : 1))
            Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
            ScrollView {
                // Two questions, two cards: "does the next message still fit?"
                // and "what did this cost?".
                VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    if let context = model.usageContext { contextCard(context) }
                    if let budget = model.selected?.run?.budget { AskBudgetView(budget: budget) }
                    if scopeOptions.count > 1 {
                        TypefluxSegmentedControl(L("ask.usage.title"), selection: $runId) {
                            ForEach(scopeOptions.indices, id: \.self) { index in
                                Text(scopeOptions[index].title).tag(scopeOptions[index].value)
                            }
                        }
                        .padding(.top, 4)
                    }
                    if model.hasUsageRecords, let totals {
                        totalsCard(totals)
                    } else if !model.hasUsageRecords || (!loading && !loadError && items.isEmpty) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "chart.pie").accessibilityHidden(true)
                            Text(L("ask.usage.empty"))
                                .font(.body).fontWeight(.semibold)
                            Text(L("ask.usage.emptyHelp")).font(.subheadline)
                        }
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("ask.usage.empty"))
                        .accessibilityHint(L("ask.usage.emptyHelp"))
                        .accessibilityIdentifier("ask.usage.empty")
                    } else if !loading {
                        Text(L("ask.usage.unavailable")).font(.callout)
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    }
                    if usage?.historicalGap == true { help("ask.usage.historicalGap") }
                    callsSection
                    if model.hasUsageRecords { help("ask.usage.scopeHelp") }
                }
                .padding(compact ? 12 : 16)
            }
            if !local, let credits = auth.usageCredits {
                Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
                HStack {
                    Text(L("ask.usage.balance"))
                    Spacer()
                    Text(credits.unlimited ? "∞" : AccountUsageDisplayFormatter.count(Int64(credits.remaining)))
                        .monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
                // Account-wide data is independently refreshed by AuthState.
            }
        }
        // A glass panel floating inset from the window edges, the sidebar's twin
        // on the trailing side, instead of a full-height column split off by a
        // rule. Classic is that column, as wide as the glass panel and its inset.
        .clipShape(RoundedRectangle(cornerRadius: style.usesGlass ? AskMetrics.sidebarPanelCorner : 0,
                                    style: .continuous))
        .frame(width: AskMetrics.usagePanelWidth + (style.usesGlass ? 0 : AskMetrics.sidebarPanelInset))
        .askSidePanel(edge: .trailing, glassFill: TypefluxColor.windowBackground.color,
                      glassInset: [.trailing, .top, .bottom],
                      floating: floating)
        .task(id: loadKey) { await load(reset: true) }
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

    /// Leads with the answer to "will the next message still fit", not with a
    /// percentage. The bar shows used input against what is left.
    private func contextCard(_ context: AskContextUsage) -> some View {
        card {
            cardLabel(L("ask.usage.remaining")) {
                Text(L(context.capacity == nil ? "ask.usage.capacityUnknown"
                        : context.isHigh ? "ask.usage.high" : "ask.usage.available"))
                    .font(.footnote).fontWeight(.medium)
                    .foregroundStyle(context.isHigh ? TypefluxColor.warning.color : TypefluxColor.success.color)
            }
            figure(context.remaining.map { "≈ " + AccountUsageDisplayFormatter.count(Int64($0)) } ?? "—",
                   unit: "tokens")
            budgetBar(context)
            HStack(spacing: 12) {
                legend(color: context.isHigh ? TypefluxColor.warning.color : TypefluxColor.accent.color,
                       title: L("ask.usage.inputEstimate"),
                       value: AccountUsageDisplayFormatter.count(Int64(context.inputTokens)))
                legend(color: TypefluxColor.separator.color,
                       title: L("ask.usage.reserve"),
                       value: AccountUsageDisplayFormatter.count(Int64(context.outputReserve)))
                if let capacity = context.capacity {
                    Text(L("ask.usage.capacity") + " " + AccountUsageDisplayFormatter.count(Int64(capacity)))
                        .font(.footnote).foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if context.summarized { help("ask.usage.summarized") }
            if context.isHigh { help("ask.usage.highHelp") }
        }
    }

    private func totalsCard(_ totals: AskUsageTotals) -> some View {
        card {
            cardLabel(L("ask.usage.spent")) {
                Text(L(runId == nil ? "ask.usage.conversation" : "ask.usage.round"))
                    .font(.footnote).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            figure(local ? totals.tokenText(totals.totalTokens) : totals.creditsText,
                   unit: local ? "tokens" : "credits")
            help(local ? "ask.usage.localHelp" : totals.statusKey)
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
                rule
                detail("ask.usage.callCount", String(totals.calls))
            }
            .padding(.top, 2)
            if totals.estimated > 0 { help("ask.usage.estimated") }
            if !local, (totals.cachedInputTokens ?? 0) > 0 { help("ask.usage.cachedHelp") }
        }
    }

    /// Individual model calls, each a row that expands in place.
    @ViewBuilder private var callsSection: some View {
        if !items.isEmpty || loading || loadError || cursor != nil {
            Text(L("ask.usage.calls")).font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rule }
                    invocation(item)
                }
                if loading { ProgressView().controlSize(.small).padding(10) }
            }
            .background(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: style), style: .continuous)
                .strokeBorder(TypefluxColor.separator.color))
            if loadError {
                Text(L("ask.usage.loadError")).font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                Button { Task { await load(reset: false) } } label: {
                    Label(L("ask.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityIdentifier("ask.usage.retry")
            } else if cursor != nil {
                Button(L("ask.usage.more")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    .font(.subheadline).foregroundStyle(TypefluxColor.accent.color)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 9 : 13)
            .background(TypefluxColor.controlBackground.color,
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: style), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: style), style: .continuous)
                .strokeBorder(TypefluxColor.separator.color))
    }

    private func cardLabel<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).fontWeight(.medium).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// The card's one large number, with its unit set small beside it.
    private func figure(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(compact ? .title : .largeTitle).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(TypefluxColor.label.color)
            Text(verbatim: unit).font(.body).fontWeight(.medium)
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var rule: some View { Rectangle().fill(TypefluxColor.separator.color).frame(height: 1) }

    private func budgetBar(_ context: AskContextUsage) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(context.isHigh ? TypefluxColor.warning.color : TypefluxColor.accent.color)
                    .frame(width: geometry.size.width * min(1, max(0, context.fraction ?? 0)))
                Rectangle().fill(TypefluxColor.controlBackground.color)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private func legend(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 7, height: 7)
            Text(title + " " + value).font(.footnote)
                .foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
        }
    }

    private func invocation(_ item: AskUsageInvocation) -> some View {
        let expanded = expandedCall == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expandedCall = expanded ? nil : item.id }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.footnote).fontWeight(.bold)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(L(item.purpose == "summary" ? "ask.usage.summary" : "ask.usage.inference"))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    Spacer(minLength: 8)
                    Text(invocationCost(item)).foregroundStyle(TypefluxColor.label.color).monospacedDigit()
                }
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.modelLibrary.name(for: item.modelRef))
                        .font(.subheadline).fontWeight(.medium).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .padding(.bottom, 4)
                    if let tokens = item.tokens {
                        detail("ask.usage.input", String(tokens.promptTokens))
                        if let cached = tokens.cachedTokens, cached > 0 {
                            detail("ask.usage.cachedInput", String(cached))
                        }
                        detail("ask.usage.output", String(tokens.completionTokens))
                        detail("ask.usage.total", String(tokens.totalTokens))
                    } else { help("ask.usage.unavailable") }
                    if item.source != "unknown" {
                        help(item.source == "estimated" ? "ask.usage.estimated"
                            : item.source == "client" ? "ask.usage.clientSource" : "ask.usage.providerSource")
                    }
                    Text(item.createdAt, style: .time).font(.footnote)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color).padding(.top, 4)
                }
                .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
    }

    private func invocationCost(_ item: AskUsageInvocation) -> String {
        if local, let tokens = item.tokens {
            return (tokens.incomplete == true ? "≥" : "")
                + AccountUsageDisplayFormatter.count(Int64(tokens.totalTokens)) + " tokens"
        }
        if local { return L(item.status == "pending" ? "ask.usage.pendingShort" : "ask.usage.unavailable") }
        if item.status == "confirmed", let amount = item.microcredits {
            return AskUsageTotals(microcredits: amount, calls: 1).creditsText + " credits"
        }
        return L(item.status == "external" ? "ask.usage.externalShort"
            : item.status == "pending" ? "ask.usage.pendingShort" : "ask.usage.unavailable")
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(L(title)).foregroundStyle(TypefluxColor.secondaryLabel.color)
            Spacer()
            Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(TypefluxColor.label.color)
        }
        .font(.callout)
        .padding(.vertical, 7)
    }

    private func help(_ key: String) -> some View { Text(L(key)).font(.footnote)
        .foregroundStyle(TypefluxColor.secondaryLabel.color).fixedSize(horizontal: false,
                                                                       vertical: true)
    }

    @MainActor private func load(reset: Bool) async {
        let id = model.selectedId
        let scope = runId
        await details.load(key: loadKey, hasRecords: id != nil && model.hasUsageRecords, reset: reset) { cursor in
            guard let id else { return AskUsagePage(items: [], nextCursor: nil) }
            return try await model.usagePage(id: id, runId: scope, cursor: cursor)
        }
    }
}
