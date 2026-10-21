// swiftlint:disable file_length
import AppKit
import SwiftUI

/// The translation surfaces are one glass layer: only the panel chrome varies by style.
enum AskTranslationAppearance {
    static func chrome(style: InterfaceStyle, increasedContrast: Bool) -> AskComposerChrome {
        var chrome = AskComposerChrome.launcher
        if !style.usesGlass, !increasedContrast {
            chrome.idleBorder = AskClassic.launcherBorder
        }
        return chrome
    }
}

/// Shared translation content; window ownership and keyboard handling stay with its host.
struct AskTranslationStackView: View {
    var stack: AskTranslationStack
    var original: String
    var actions: [AskPluginAction]
    var selected = 0
    var starred = false
    var comparing = false
    var running = false
    var viewportHeight: CGFloat?
    /// The panel shows the language pair in its title bar instead.
    var showsLanguageBar = true
    var defaults: UserDefaults?
    var onAction: (AskPluginAction) -> Void
    var onSelect: (String) -> Bool = { _ in true }

    static let maximumHeight: CGFloat = 500
    static let languageBarHeight: CGFloat = 30
    static let compareLabelHeight: CGFloat = 24
    static let resultSpacing: CGFloat = 8

    static func height(_ stack: AskTranslationStack, comparing: Bool = false) -> CGFloat {
        let rows = stack.results.enumerated().reduce(CGFloat.zero) { height, item in
            let (index, row) = item
            let gap: CGFloat = index == 0 ? 0 : (showsCompareLabel(stack, before: index) ? compareLabelHeight : resultSpacing)
            if let card = row.card {
                return height + gap + 34 + AskWordCardView.height(card, stackStyle: true) + 14
            }
            let content = row.text.map { AskPluginResultsView.bodyHeight($0) } ?? 22
            return height + gap + 34 + content + 14
        }
        return min(maximumHeight, languageBarHeight + 8 + (comparing ? 64 : 0) + max(44, rows))
    }

    /// In a lookup the other services follow the word card under a "Compare" label.
    static func showsCompareLabel(_ stack: AskTranslationStack, before index: Int) -> Bool {
        stack.isLookup && index == 1 && stack.results.first?.card != nil
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsLanguageBar {
                languageBar
                    .translationContentHeight(.languages, enabled: viewportHeight != nil)
            }
            if comparing {
                Text(original).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9))
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if stack.results.isEmpty {
                            Text(L(stack.submitted ? "ask.translation.stack.empty" : "ask.translation.stack.ready"))
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textTertiary)
                                .padding(14)
                        }
                        ForEach(Array(stack.results.enumerated()), id: \.element.id) { index, result in
                            if index > 0 {
                                divider(before: index)
                            }
                            AskTranslationResultView(result: result, stack: stack, original: original,
                                                     number: index + 1, selected: selected == index,
                                                     actions: actions, starred: starred, running: running,
                                                     defaults: defaults,
                                                     onAction: onAction,
                                                     onSelect: { _ = onSelect(result.id) })
                                .id(result.id)
                        }
                    }
                    .translationContentHeight(.results, enabled: viewportHeight != nil)
                }
                .onChange(of: selected) { index in
                    guard stack.results.indices.contains(index) else { return }
                    proxy.scrollTo(stack.results[index].id, anchor: .center)
                }
            }
        }
        .frame(height: viewportHeight ?? Self.height(stack, comparing: comparing))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.stack")
    }

    /// A hairline centered in the gap, hidden next to the selected row so it never crosses its fill.
    @ViewBuilder private func divider(before index: Int) -> some View {
        if Self.showsCompareLabel(stack, before: index) {
            Text(L("ask.translation.stack.compare")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: Self.compareLabelHeight, alignment: .bottomLeading)
                .padding(.leading, 12).padding(.bottom, 3)
        } else {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
                .frame(height: Self.resultSpacing)
                .opacity(selected == index || selected == index - 1 ? 0 : 1)
        }
    }

    var languageBar: some View {
        AskTranslationLanguagePair(stack: stack, onAction: onAction)
            .frame(maxWidth: .infinity, minHeight: Self.languageBarHeight, alignment: .leading)
    }
}

/// `Detected English ⌄  ⇄  Simplified Chinese ⌄`: borderless menus, the target in the accent colour.
struct AskTranslationLanguagePair: View {
    var stack: AskTranslationStack
    var onAction: (AskPluginAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button(L("ask.translation.stack.detect")) { rerun(["source": ""]) }
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Button(AskTranslationLanguages.name(code, in: stack.interface)) { rerun(["source": code]) }
                }
            } label: {
                Text(sourceLabel).foregroundStyle(StudioTheme.textPrimary)
            }
            .menuStyle(.borderlessButton).tint(StudioTheme.textPrimary).fixedSize()
            .padding(.horizontal, 6).frame(height: 28)
            .accessibilityIdentifier("ask.translation.languages.source")
            Button {
                if let text = stack.results.first?.completedText, let source = stack.source {
                    onAction(.init(kind: .swapTranslation(text, source: stack.target, target: source),
                                   title: "", symbol: ""))
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(stack.results.first?.completedText == nil || stack.source == nil)
            .help(L("ask.translation.stack.swap") + " · ⌘⇧S")
            .accessibilityLabel(L("ask.translation.stack.swap"))
            Menu {
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Button(AskTranslationLanguages.name(code, in: stack.interface)) {
                        rerun([AskTranslatePlugin.targetOption: code])
                    }
                }
            } label: {
                Text(AskTranslationLanguages.name(stack.target, in: stack.interface)).foregroundStyle(AskTheme.accent)
            }
            .menuStyle(.borderlessButton).tint(AskTheme.accent).fixedSize()
            .padding(.horizontal, 6).frame(height: 28)
            .accessibilityIdentifier("ask.translation.languages.target")
        }
        .font(.system(size: 13, weight: .semibold))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.languages")
    }

    private func rerun(_ options: [String: String]) {
        onAction(.init(kind: .rerun(options), title: "", symbol: ""))
    }

    var sourceLabel: String {
        Self.sourceLabel(stack)
    }

    static func sourceLabel(_ stack: AskTranslationStack) -> String {
        let language = stack.source.map { AskTranslationLanguages.name($0, in: stack.interface) }
        guard stack.sourceIsAutomatic else { return language ?? L("ask.translation.stack.detect") }
        return language.map { L("ask.translation.stack.detected", $0) } ?? L("ask.translation.stack.detect")
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
                Image(systemName: service.symbol).aiSymbolTint(service.symbol).font(.system(size: 10, weight: .semibold))
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
    @AppStorage private var collapsePreference: Int
    private var compact: Bool {
        result.isCollapsed(preference: collapsePreference, lookup: stack.isLookup)
    }

    init(result: AskTranslationResult, stack: AskTranslationStack, original: String, number: Int,
         selected: Bool, actions: [AskPluginAction], starred: Bool, running: Bool,
         defaults: UserDefaults?, onAction: @escaping (AskPluginAction) -> Void, onSelect: @escaping () -> Void) {
        self.result = result
        self.stack = stack
        self.original = original
        self.number = number
        self.selected = selected
        self.actions = actions
        self.starred = starred
        self.running = running
        self.onAction = onAction
        self.onSelect = onSelect
        _collapsePreference = AppStorage(wrappedValue: 0, result.collapseKey, store: defaults)
    }

    /// Selection is a soft accent fill and hover a neutral wash; rows have no borders.
    private var fill: Color {
        if selected {
            return AskTheme.accent.opacity(0.14)
        }
        return hovering ? AskTheme.hoverFill : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !compact {
                content.padding(.leading, 25)
            }
        }
        .padding(.horizontal, 10).padding(.top, compact ? 7 : 8).padding(.bottom, compact ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.result." + result.id)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                collapsePreference = compact ? 2 : 1
            } label: {
                Image(systemName: compact ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
            .accessibilityLabel(L(compact ? "ask.translation.stack.expand" : "ask.translation.stack.collapse"))
            .accessibilityIdentifier("ask.translation.result." + result.id + ".collapse")
            AskTranslationServiceIcon(service: result.service)
            Text(result.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1).layoutPriority(1)
            if result.card != nil || (!compact && result.service.kind == .device) {
                Text(L(result.fromWordBook ? "ask.plugin.source.wordBook" : result
                        .card != nil ? "ask.translation.stack.card" : "ask.translation.stack.private"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(result.fromWordBook ? AskTheme.accent : StudioTheme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(
                        result.fromWordBook ? AskTheme.accent.opacity(0.14) : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            if compact {
                compactSummary
            }
            Spacer(minLength: 4)
            if result.completedText != nil {
                tools.opacity(hovering || selected ? 1 : 0).allowsHitTesting(hovering || selected)
            }
            if number <= 9 {
                Text("⌘\(number)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
        }
        .font(.system(size: 11.5))
        .frame(minHeight: 22)
        .contentShape(Rectangle()).onTapGesture(perform: onSelect)
    }

    @ViewBuilder private var compactSummary: some View {
        switch result.state {
        case let .failed(failure):
            Text(failure.message).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            if let action = failure.action(for: result.service) {
                recoveryButton(action)
            }
        case .loading: ProgressView().controlSize(.mini)
        default:
            Text(result.text ?? "").font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder private var content: some View {
        switch result.state {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("ask.translation.stack.loading")) }
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        case let .failed(failure):
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.warning)
                Text(failure.message).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let action = failure.action(for: result.service) {
                    recoveryButton(action)
                }
            }
            .font(.system(size: 12.5))
        case let .streaming(text):
            Text(text + AskPluginResultsView.caret).font(.system(size: 14.5)).lineSpacing(3)
                .foregroundStyle(StudioTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        case let .done(text, card):
            if let card {
                AskWordCardView(card: card, language: stack.source ?? "en", stackStyle: true, onAction: onAction)
            } else {
                Text(text).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func recoveryButton(_ action: AskPluginAction) -> some View {
        Button(action.title) { onAction(action) }
            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .disabled(running)
            .accessibilityIdentifier("ask.translation.result." + result.id + ".recovery")
    }

    /// Word card actions join the row's own tools; their shortcuts live in the help tags and footer.
    private func cardAction(_ shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        guard result.card != nil else { return nil }
        return actions.first { $0.shortcut == shortcut }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            if let star = cardAction(.commandS) {
                tool(starred ? "star.fill" : "star", help: star.title + " · ⌘S",
                     id: "star", tint: starred ? AskTheme.accent : nil) { onAction(star) }
            }
            if let regenerate = cardAction(.commandR) {
                tool("arrow.clockwise", help: regenerate.title + " · ⌘R", id: "regenerate") { onAction(regenerate) }
                    .disabled(running)
            }
            tool("speaker.wave.2", help: L("ask.plugin.action.speak"), id: "speak") {
                onAction(.init(kind: .speak(result.completedText ?? "", language: stack.target), title: "", symbol: ""))
            }
            tool("arrow.turn.down.left", help: L("ask.plugin.action.insert") + " · ⌥↩", id: "insert") {
                onAction(AskTranslatePlugin.insertAction(result.completedText ?? "", replaces: stack.replacesSelection))
            }
            .disabled(result.card != nil && result.card?.translatedText == nil)
            Menu {
                AskTranslationCopyOptions(result: result, original: original,
                                          replacesSelection: stack.replacesSelection, onAction: onAction)
            } label: { Image(systemName: "doc.on.doc") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(StudioTheme.textTertiary).fixedSize()
                .frame(width: 24, height: 22)
                .help(L("ask.plugin.action.copy"))
                .accessibilityIdentifier("ask.translation.result." + result.id + ".copyMenu")
        }
        .font(.system(size: 11.5))
    }

    private func tool(_ symbol: String, help: String, id: String, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint ?? StudioTheme.textTertiary)
        .help(help).accessibilityLabel(help)
        .accessibilityIdentifier("ask.translation.result." + result.id + "." + id)
    }
}

/// Actions offered by each completed result's copy menu.
struct AskTranslationCopyOptions: View {
    var result: AskTranslationResult
    var original: String
    var replacesSelection: Bool
    var onAction: (AskPluginAction) -> Void

    var body: some View {
        Button(L("ask.translation.stack.copyTranslation")) {
            onAction(AskTranslatePlugin.copyAction(result.completedText ?? ""))
        }
        Button(L("ask.translation.stack.copyBoth")) {
            if let action = result.copyBoth(original: original) {
                onAction(action)
            }
        }
        .accessibilityIdentifier("ask.translation.result." + result.id + ".copyBoth")
        if let card = result.card {
            Button(L("ask.plugin.action.copyCard")) { onAction(AskTranslatePlugin.copyAction(card.markdown)) }
        }
        Divider()
        Button(L("ask.plugin.action.insert")) {
            onAction(AskTranslatePlugin.insertAction(result.completedText ?? "", replaces: replacesSelection))
        }
        .disabled(result.card != nil && result.card?.translatedText == nil)
    }
}
