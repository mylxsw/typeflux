import SwiftUI

/// The context budget as a ring plus one percentage, sized to live inside the
/// composer footer. It replaced a full-width row under the composer that spent
/// a whole line restating what the panel already explains in detail.
struct AskContextUsageButton: View {
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
                .frame(width: 15, height: 15)
                Text(context.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 28)
            .background(hovering ? AskTheme.controlSurface : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @ObservedObject private var auth = AuthState.shared
    @Binding var runId: String?
    var close: () -> Void
    @State private var items: [AskUsageInvocation] = []
    @State private var cursor: Int64?
    @State private var loading = false
    @State private var loadError = false

    private var usage: AskConversationUsage? { model.selected?.usage }
    private var totals: AskUsageTotals? { runId.flatMap { usage?.runs[$0] } ?? (runId == nil ? usage?.total : nil) }
    private var loadKey: String { "\(model.selectedId ?? "")/\(usage?.version ?? 0)/\(runId ?? "all")" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("ask.usage.title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel(L("ask.usage.close"))
            }.padding(.horizontal, 18).frame(height: AskMetrics.titleBarRowHeight)
            Divider()
            ScrollView {
                // Two questions, two cards: "does the next message still fit?"
                // and "what did this cost?". They used to share one column of
                // twelve equally weighted number rows.
                VStack(alignment: .leading, spacing: 12) {
                    if let context = model.usageContext { contextCard(context) }
                    Picker(L("ask.usage.scope"), selection: $runId) {
                        if let current = runId ?? model.selected?.run?.id {
                            Text(L("ask.usage.round")).tag(Optional(current))
                        }
                        Text(L("ask.usage.conversation")).tag(String?.none)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if let totals {
                        totalsCard(totals)
                    } else {
                        Text(L("ask.usage.unavailable")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    if usage?.historicalGap == true { help("ask.usage.historicalGap") }
                    Text(L("ask.usage.calls")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.top, 4)
                    ForEach(items) { item in invocation(item) }
                    if loading { ProgressView().controlSize(.small) }
                    if loadError {
                        Text(L("ask.usage.loadError")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                        Button(L("ask.retry")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    } else if cursor != nil {
                        Button(L("ask.usage.more")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    }
                    help("ask.usage.scopeHelp")
                }.padding(16)
            }
            if let credits = auth.usageCredits {
                Divider()
                HStack {
                    Text(L("ask.usage.balance"))
                    Spacer()
                    Text(credits.unlimited ? "∞" : AccountUsageDisplayFormatter.count(Int64(credits.remaining)))
                }.font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).padding(16)
                // Account-wide data is independently refreshed by AuthState.
            }
        }
        .frame(width: 330).background(AskTheme.raisedSurface)
        .overlay(alignment: .leading) { Rectangle().fill(AskTheme.border).frame(width: 1) }
        .task(id: loadKey) { await load(reset: true) }
        .onExitCommand(perform: close)
    }

    /// Leads with the answer to "will the next message still fit", not with a
    /// percentage. The bar shows used input, reserved output and what is left.
    private func contextCard(_ context: AskContextUsage) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text(L("ask.usage.remaining")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 8)
                Text(L(context.capacity == nil ? "ask.usage.capacityUnknown"
                       : context.isHigh ? "ask.usage.high" : "ask.usage.available"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(context.isHigh ? StudioTheme.warning : StudioTheme.success)
            }
            Text(context.remaining.map { "≈" + AccountUsageDisplayFormatter.count(Int64($0)) } ?? "—")
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
            budgetBar(context)
            HStack(spacing: 12) {
                legend(color: context.isHigh ? StudioTheme.warning : AskTheme.accent,
                       title: L("ask.usage.inputEstimate"),
                       value: AccountUsageDisplayFormatter.count(Int64(context.inputTokens)))
                legend(color: AskTheme.border,
                       title: L("ask.usage.reserve"),
                       value: AccountUsageDisplayFormatter.count(Int64(context.outputReserve)))
                Spacer(minLength: 0)
            }
            Text(model.modelLibrary.name(for: context.modelRef) + " · " + L("ask.usage.capacity") + " "
                 + (context.capacity.map { AccountUsageDisplayFormatter.count(Int64($0)) } ?? "—"))
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if context.summarized { help("ask.usage.summarized") }
            if context.isHigh { help("ask.usage.highHelp") }
        }
    }

    private func totalsCard(_ totals: AskUsageTotals) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text(L("ask.usage.title")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 8)
                Text(L(runId == nil ? "ask.usage.conversation" : "ask.usage.round"))
                    .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            Text(totals.creditsText + " credits")
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
            help(totals.statusKey)
            detail("ask.usage.input", totals.tokenText(totals.inputTokens))
            detail("ask.usage.output", totals.tokenText(totals.outputTokens))
            detail("ask.usage.total", totals.tokenText(totals.totalTokens))
            detail("ask.usage.callCount", String(totals.calls))
            if totals.estimated > 0 { help("ask.usage.estimated") }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(AskTheme.border))
    }

    private func budgetBar(_ context: AskContextUsage) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(context.isHigh ? StudioTheme.warning : AskTheme.accent)
                    .frame(width: geometry.size.width * min(1, max(0, context.fraction ?? 0)))
                Rectangle().fill(AskTheme.border)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func legend(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 7, height: 7)
            Text(title + " " + value).font(.system(size: 10.5))
                .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
        }
    }

    private func invocation(_ item: AskUsageInvocation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.modelLibrary.name(for: item.modelRef))
                if let tokens = item.tokens {
                    detail("ask.usage.input", String(tokens.promptTokens))
                    detail("ask.usage.output", String(tokens.completionTokens))
                    detail("ask.usage.total", String(tokens.totalTokens))
                } else { help("ask.usage.unavailable") }
                if item.source != "unknown" {
                    help(item.source == "estimated" ? "ask.usage.estimated" : item.source == "client" ? "ask.usage.clientSource" : "ask.usage.providerSource")
                }
                Text(item.createdAt, style: .time).foregroundStyle(StudioTheme.textSecondary)
            }.padding(.vertical, 8).font(.system(size: 11))
        } label: {
            HStack {
                Text(L(item.purpose == "summary" ? "ask.usage.summary" : "ask.usage.inference"))
                Spacer()
                if item.status == "confirmed", let amount = item.microcredits {
                    Text(AskUsageTotals(microcredits: amount, calls: 1).creditsText + " credits")
                } else { Text(L(item.status == "external" ? "ask.usage.externalShort" : item.status == "pending" ? "ask.usage.pendingShort" : "ask.usage.unavailable")) }
            }.font(.system(size: 10))
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(L(title)).foregroundStyle(StudioTheme.textSecondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 11))
    }
    private func help(_ key: String) -> some View { Text(L(key)).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true) }

    @MainActor private func load(reset: Bool) async {
        let key = loadKey
        guard let id = model.selectedId else { return }
        if reset { items = []; cursor = nil }
        loading = true; loadError = false
        do {
            let page = try await model.usagePage(id: id, runId: runId, cursor: reset ? nil : cursor)
            guard !Task.isCancelled, key == loadKey else { return }
            let existing = Set(items.map(\.id))
            items += page.items.filter { !existing.contains($0.id) }; cursor = page.nextCursor; loading = false
        } catch {
            guard !Task.isCancelled, key == loadKey else { return }
            loading = false; loadError = true
        }
    }
}
