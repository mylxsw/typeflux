import SwiftUI

struct AskContextUsageButton: View {
    let context: AskContextUsage
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(AskTheme.border, lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, context.fraction ?? 0))
                        .stroke(context.isHigh ? Color.orange : AskTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 12, height: 12)
                Text(L("ask.usage.context") + " ≈" + AccountUsageDisplayFormatter.count(Int64(context.inputTokens)))
                if let fraction = context.fraction { Text("· \(Int(fraction * 100))%") }
                Image(systemName: "chevron.up").font(.system(size: 8))
            }
            .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(L("ask.usage.contextHelp"))
        .accessibilityLabel(L("ask.usage.contextHelp"))
    }
}

struct AskUsageSummaryButton: View {
    var totals: AskUsageTotals?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                if let totals {
                    Text(L("ask.usage.output") + " " + totals.tokenText(totals.outputTokens))
                    Text("· " + totals.creditsText + " credits")
                    if totals.pending > 0 { Text(L("ask.usage.pendingShort")) }
                } else { Text(L("ask.usage.unavailable")) }
            }
            .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
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
                VStack(alignment: .leading, spacing: 18) {
                    if let context = model.usageContext { contextSection(context) }
                    Divider()
                    Picker(L("ask.usage.scope"), selection: $runId) {
                        if let current = runId ?? model.selected?.run?.id {
                            Text(L("ask.usage.round")).tag(Optional(current))
                        }
                        Text(L("ask.usage.conversation")).tag(String?.none)
                    }.pickerStyle(.segmented)
                    if let totals {
                        totalsSection(totals)
                    } else {
                        Text(L("ask.usage.unavailable")).foregroundStyle(StudioTheme.textSecondary)
                    }
                    if usage?.historicalGap == true { help("ask.usage.historicalGap") }
                    Divider()
                    Text(L("ask.usage.calls")).font(.system(size: 12, weight: .medium))
                    ForEach(items) { item in invocation(item) }
                    if loading { ProgressView().controlSize(.small) }
                    if loadError {
                        Text(L("ask.usage.loadError")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                        Button(L("ask.retry")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    } else if cursor != nil {
                        Button(L("ask.usage.more")) { Task { await load(reset: false) } }.buttonStyle(.plain)
                    }
                }.padding(18)
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

    private func contextSection(_ context: AskContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ask.usage.context")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            HStack(alignment: .firstTextBaseline) {
                Text(context.fraction.map { "≈\(Int($0 * 100))%" } ?? "—").font(.system(size: 27, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(L(context.capacity == nil ? "ask.usage.capacityUnknown" : context.isHigh ? "ask.usage.high" : "ask.usage.available"))
                    .font(.system(size: 10)).foregroundStyle(context.isHigh ? Color.orange : StudioTheme.textSecondary)
            }
            if let fraction = context.fraction {
                ProgressView(value: min(1, fraction)).tint(context.isHigh ? .orange : AskTheme.accent)
            }
            detail("ask.usage.inputEstimate", AccountUsageDisplayFormatter.count(Int64(context.inputTokens)))
            detail("ask.usage.reserve", AccountUsageDisplayFormatter.count(Int64(context.outputReserve)))
            detail("ask.usage.capacity", context.capacity.map { AccountUsageDisplayFormatter.count(Int64($0)) } ?? "—")
            detail("ask.usage.remaining", context.remaining.map { "≈" + AccountUsageDisplayFormatter.count(Int64($0)) } ?? "—")
            Text(model.modelLibrary.name(for: context.modelRef)).font(.system(size: 11))
            help("ask.usage.contextHelp")
            if context.summarized { help("ask.usage.summarized") }
            if context.isHigh { help("ask.usage.highHelp") }
        }
    }

    private func totalsSection(_ totals: AskUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(totals.creditsText + " credits").font(.system(size: 25, weight: .semibold)).monospacedDigit()
            help(totals.statusKey)
            HStack {
                metric("ask.usage.input", totals.tokenText(totals.inputTokens))
                metric("ask.usage.output", totals.tokenText(totals.outputTokens))
            }
            detail("ask.usage.total", totals.tokenText(totals.totalTokens))
            detail("ask.usage.callCount", String(totals.calls))
            if totals.estimated > 0 { help("ask.usage.estimated") }
            help("ask.usage.scopeHelp")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 9))
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
