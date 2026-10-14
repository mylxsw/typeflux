import AppKit
import SwiftUI

/// Shared translation content; window ownership and keyboard handling stay with its host.
struct AskTranslationStackView: View {
    var stack: AskTranslationStack
    var original: String
    var actions: [AskPluginAction]
    var selected = 0
    var starred = false
    var comparing = false
    var running = false
    var onAction: (AskPluginAction) -> Void
    var onSelect: (String) -> Bool = { _ in true }

    static let maximumHeight: CGFloat = 500
    static func height(_ stack: AskTranslationStack, comparing: Bool = false) -> CGFloat {
        let rows = stack.results.reduce(CGFloat.zero) { height, row in
            if let card = row.card {
                return height + 40 + AskWordCardView.height(card, stackStyle: true) + 38
            }
            if stack.isLookup {
                return height + 40
            }
            let content = row.text.map { AskPluginResultsView.bodyHeight($0) } ?? 22
            return height + 38 + content + 14
        }
        return min(maximumHeight, 38 + (comparing ? 64 : 0) + max(44, rows) + CGFloat(stack.results.count * 5))
    }

    var body: some View {
        VStack(spacing: 8) {
            languageBar
            if comparing {
                Text(original).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9))
            }
            ScrollView(.vertical) {
                VStack(spacing: 5) {
                    if stack.results.isEmpty {
                        Text(L("ask.translation.stack.empty")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(14)
                    }
                    ForEach(Array(stack.results.enumerated()), id: \.element.id) { index, result in
                        AskTranslationResultView(result: result, stack: stack, original: original,
                                                 number: index + 1, selected: selected == index,
                                                 actions: actions, starred: starred, running: running,
                                                 onAction: onAction,
                                                 onSelect: { _ = onSelect(result.id) })
                    }
                }
            }
        }
        .frame(height: Self.height(stack, comparing: comparing))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.stack")
    }

    var languageBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button(L("ask.translation.stack.detect")) { onAction(.init(
                    kind: .rerun(["source": ""]),
                    title: "",
                    symbol: ""
                )) }
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Button(AskTranslationLanguages.name(code, in: stack.interface)) {
                        onAction(.init(kind: .rerun(["source": code]), title: "", symbol: ""))
                    }
                }
            } label: {
                Text(sourceLabel)
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            .menuStyle(.borderlessButton).tint(StudioTheme.textPrimary)
            .frame(maxWidth: .infinity).padding(.horizontal, 10).frame(height: 30)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8))
            Button {
                if let text = stack.results.first?.completedText, let source = stack.source {
                    onAction(.init(
                        kind: .swapTranslation(text, source: stack.target, target: source),
                        title: "",
                        symbol: ""
                    ))
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .buttonStyle(.plain).disabled(stack.results.first?.completedText == nil || stack.source == nil)
            .help(L("ask.translation.stack.swap"))
            Menu {
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Button(AskTranslationLanguages.name(code, in: stack.interface)) {
                        onAction(.init(kind: .rerun([AskTranslatePlugin.targetOption: code]), title: "", symbol: ""))
                    }
                }
            } label: {
                Text(AskTranslationLanguages.name(stack.target, in: stack.interface)).foregroundStyle(AskTheme.accent)
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton).tint(AskTheme.accent)
            .frame(maxWidth: .infinity).padding(.horizontal, 10).frame(height: 30)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .font(.system(size: 12))
        .accessibilityIdentifier("ask.translation.languages")
    }

    private var sourceLabel: String {
        let language = stack.source.map { AskTranslationLanguages.name($0, in: stack.interface) }
        guard stack.sourceIsAutomatic else { return language ?? L("ask.translation.stack.detect") }
        return L("ask.translation.stack.detect") + (language.map { " · " + $0 } ?? "")
    }
}

struct AskTranslationServiceIcon: View {
    var service: AskTranslationService
    private var color: Color {
        switch service.kind {
        case .device: .gray
        case .ai: AskTheme.accent
        case let .provider(provider):
            switch provider {
            case .deepl: Color(red: 0.05, green: 0.18, blue: 0.29)
            case .youdao: .red
            case .google, .baidu: .blue
            case .microsoft, .tencent: .cyan
            case .volcengine: .orange
            }
        }
    }

    var body: some View {
        Group {
            if let provider = service.provider {
                Text(String(provider.title.prefix(1))).font(.system(
                    size: 10,
                    weight: .bold
                ))
            } else {
                Image(systemName: service.symbol).font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(.white).frame(width: 19, height: 19)
        .background(color, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct AskTranslationResultView: View {
    var result: AskTranslationResult
    var stack: AskTranslationStack
    var original: String
    var number: Int
    var selected: Bool
    var actions: [AskPluginAction]
    var starred: Bool
    var running: Bool
    var onAction: (AskPluginAction) -> Void
    var onSelect: () -> Void
    @State private var hovering = false
    @State private var collapsed = false
    @State private var expandedLookup = false
    private var compact: Bool {
        collapsed || (stack.isLookup && result.card == nil && !expandedLookup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !compact {
                content.padding(.leading, result.card == nil ? 25 : 22)
                if result.card != nil {
                    wordActions.padding(.leading, 22).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(
            selected ? AskTheme.accent.opacity(0.8) : .clear,
            lineWidth: 1
        ) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.result." + result.id)
    }

    private var header: some View {
        HStack(spacing: 6) {
            AskTranslationServiceIcon(service: result.service)
            Text(result.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1)
            if result.card != nil || (!compact && result.service.kind == .device) {
                Text(L(result.fromWordBook ? "ask.plugin.source.wordBook" : result
                        .card != nil ? "ask.translation.stack.card" : "ask.translation.stack.private"))
                    .font(.system(size: 10))
                    .foregroundStyle(result.card != nil ? AskTheme.accent : StudioTheme.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        result.card != nil ? AskTheme.accent.opacity(0.13) : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            if compact {
                switch result.state {
                case let .failed(failure):
                    Text(failure.message).foregroundStyle(StudioTheme.danger).lineLimit(1)
                    if let action = failure
                        .action(for: result.service) {
                        Button(action.title) { onAction(action) }.buttonStyle(.plain).foregroundStyle(AskTheme.accent)
                            .disabled(running)
                            .accessibilityIdentifier("ask.translation.result." + result.id + ".recovery")
                    }
                case .loading: ProgressView().controlSize(.mini)
                default: Text(result.text ?? "").foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if result
                .completedText !=
                nil {
                tools.opacity(hovering || selected ? 1 : 0).allowsHitTesting(hovering || selected)
            }
            if number <= 9 {
                Text("⌘\(number)").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            }
            Button {
                if stack.isLookup, result.card == nil {
                    expandedLookup.toggle()
                } else {
                    collapsed.toggle()
                }
            } label: { Image(systemName: compact ? "chevron.right" : "chevron.down").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                .accessibilityLabel(L(compact ? "ask.translation.stack.expand" : "ask.translation.stack.collapse"))
        }
        .font(.system(size: 11.5))
        .contentShape(Rectangle()).onTapGesture(perform: onSelect)
    }

    @ViewBuilder private var content: some View {
        switch result.state {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("ask.translation.stack.loading")) }
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        case let .failed(failure):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(failure.message).foregroundStyle(StudioTheme.danger).fixedSize(horizontal: false, vertical: true)
                if let action = failure.action(for: result.service) {
                    Button(action.title) { onAction(action) }.buttonStyle(.plain).foregroundStyle(AskTheme.accent)
                        .disabled(running).accessibilityIdentifier("ask.translation.result." + result.id + ".recovery")
                }
            }
            .font(.system(size: 12))
        case let .streaming(text):
            Text(text + AskPluginResultsView.caret).font(.system(size: 14)).foregroundStyle(StudioTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        case let .done(text, card):
            if let card {
                AskWordCardView(card: card, language: stack.source ?? "en", stackStyle: true, onAction: onAction)
            } else {
                Text(text).font(.system(size: 14)).foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 7) {
            Button {
                onAction(.init(kind: .speak(result.completedText ?? "", language: stack.target), title: "", symbol: ""))
            } label: { Image(systemName: "speaker.wave.2") }.help(L("ask.plugin.action.speak"))
            Button { onAction(AskTranslatePlugin.insertAction(
                result.completedText ?? "",
                replaces: stack.replacesSelection
            )) } label: { Image(systemName: "text.insert") }
                .help(L("ask.plugin.action.insert"))
                .disabled(result.card != nil && result.card?.translatedText == nil)
            Menu {
                Button(L("ask.translation.stack.copyTranslation")) {
                    onAction(AskTranslatePlugin.copyAction(result.completedText ?? ""))
                }
                Button(L("ask.translation.stack.copyBoth")) {
                    onAction(AskTranslatePlugin.copyAction(original + "\n\n" + (result.completedText ?? "")))
                }
                if let card = result.card {
                    Button(L("ask.plugin.action.copyCard")) { onAction(AskTranslatePlugin.copyAction(card.markdown)) }
                }
                Divider()
                Button(L("ask.plugin.action.insert")) { onAction(AskTranslatePlugin.insertAction(
                    result.completedText ?? "",
                    replaces: stack.replacesSelection
                )) }
                .disabled(result.card != nil && result.card?.translatedText == nil)
            } label: { Image(systemName: "doc.on.doc") }
                .menuStyle(.borderlessButton).tint(StudioTheme.textTertiary).fixedSize()
                .help(L("ask.plugin.action.copy"))
        }
        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
    }

    private var wordActions: some View {
        HStack(spacing: 5) {
            ForEach(
                Array([AskPluginAction.Shortcut.commandS, .shiftCommandC, .commandR, .commandB]
                    .compactMap { shortcut in actions.first { $0.shortcut == shortcut } }.enumerated()),
                id: \.offset
            ) { _, action in
                Button { onAction(action) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.shortcut == .commandS && starred ? "star.fill" : action.symbol)
                        Text(action.title)
                        Text(key(action.shortcut)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .font(.system(size: 10.5)).padding(.horizontal, 7).frame(height: 23)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
                .disabled(running && action.shortcut == .commandR)
            }
        }
    }

    private func key(_ shortcut: AskPluginAction.Shortcut?) -> String {
        switch shortcut {
        case .commandS: "⌘S"
        case .shiftCommandC: "⇧⌘C"
        case .commandR: "⌘R"
        case .commandB: "⌘B"
        default: ""
        }
    }
}

struct AskTranslationConfigurationPresenter: View {
    @ObservedObject var model: AskTranslationSettingsModel
    var onConfigured: (AskTranslationProvider) -> Void = { _ in }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { model.editing != nil }, set: {
                if !$0 {
                    model.cancelEdit()
                }
            })) {
                if let provider = model.editing {
                    AskTranslationProviderSheet(model: model, provider: provider, onSaved: { onConfigured(provider) })
                }
            }
    }
}
