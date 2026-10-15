import AppKit
import SwiftUI

/// Native panel chrome around the same word card and services as `fy`. One glass surface:
/// the language pair is the title, the original sits directly on the glass and rows have no borders.
struct AskTranslationPanelView: View {
    @ObservedObject var model: AskTranslationPanelModel
    @ObservedObject var history: AskTranslationHistory
    var height: CGFloat
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @State private var editorHeight: CGFloat = Self.minimumEditorHeight
    @State private var measuredChromeHeight: CGFloat?
    @State private var showsShortcuts = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let minimumEditorHeight: CGFloat = 33
    static let maximumEditorHeight: CGFloat = 108
    static let titleHeight: CGFloat = 44
    static let footerHeight: CGFloat = 30
    static let recentLimit = 5

    private var chrome: AskComposerChrome {
        AskTranslationAppearance.chrome(style: style, increasedContrast: contrast == .increased)
    }

    private var material: AskGlassMaterial {
        AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style)
    }

    static func chromeHeight(screenshot: Bool) -> CGFloat {
        screenshot ? 172 : 146
    }

    /// Everything but the results, before the panel has measured itself.
    static func estimatedChromeHeight(text: String, screenshot: Bool, notice: Bool) -> CGFloat {
        let lines = CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let editor = min(maximumEditorHeight, max(minimumEditorHeight, lines * 25 + 8))
        return chromeHeight(screenshot: screenshot) + editor - minimumEditorHeight + (notice ? 24 : 0)
    }

    /// The empty panel offers recent translations instead of a blank area.
    private var showsRecent: Bool {
        model.text.isEmpty && model.output == nil && !history.entries.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
                .translationContentHeight(.title)
            original
                .translationContentHeight(.original)
            if showsRecent {
                recent
                    .translationContentHeight(.results)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                AskTranslationStackView(stack: model.stack, original: model.output?.original ?? model.text,
                                        actions: model.output?.actions ?? [], selected: model.output?.selectedItem ?? 0,
                                        starred: model.output?.starred == true, running: model.running,
                                        viewportHeight: max(
                                            42,
                                            height - (measuredChromeHeight
                                                ?? (Self.chromeHeight(screenshot: model.screenshot != nil)
                                                    + editorHeight - Self.minimumEditorHeight
                                                    + (model.notice == nil ? 0 : 24)))
                                        ),
                                        showsLanguageBar: false,
                                        defaults: model.settings.defaults,
                                        onAction: model.perform, onSelect: model.select)
                    .padding(.horizontal, 6)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(StudioTheme.danger)
                    .lineLimit(2).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .translationContentHeight(.notice)
            }
            footer
                .translationContentHeight(.footer)
        }
        .onPreferenceChange(AskTranslationContentHeight.self) { heights in
            let required: [AskTranslationContentHeight.Part] = [.title, .original, .results, .footer]
            guard required.allSatisfy({ heights[$0] != nil }) else { return }
            let chromeParts: [AskTranslationContentHeight.Part] = [.title, .original, .notice, .footer]
            let chrome = chromeParts.reduce(CGFloat.zero) { $0 + (heights[$1] ?? 0) }
                + (heights[.notice] == nil ? 18 : 24) + AskMetrics.launcherGutter * 2
            measuredChromeHeight = chrome
            onContentHeightChange(chrome + (heights[.results] ?? 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(chrome.glassBackground(material))
        .clipShape(RoundedRectangle(cornerRadius: chrome.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: chrome.corner, style: .continuous)
                .strokeBorder(chrome.idleBorder(on: material, increasedContrast: contrast == .increased), lineWidth: 1)
        }
        .padding(AskMetrics.launcherGutter)
        .tint(AskTheme.accent)
        .background(AskTranslationConfigurationPresenter(model: model.configuration, onConfigured: { provider in
            model.translate(options: ["retryService": "provider." + provider.rawValue])
        }, onLanguagesReady: model.retryDownloadedLanguages))
        .accessibilityIdentifier("ask.translation.panel")
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                AskTranslationLanguagePair(stack: model.stack, onAction: model.perform)
                Spacer(minLength: 8)
            }
            .frame(maxHeight: .infinity)
            .background(AskTranslationTitleDragArea())
            sourceChip
            Menu {
                if history.entries.isEmpty {
                    Text(L("ask.translation.panel.history.empty"))
                }
                ForEach(history.entries, id: \.self) { text in
                    Button(String(text.prefix(70))) { model.chooseHistory(text) }
                }
                Divider()
                Button(L("ask.translation.panel.history.clear"), role: .destructive) { model.clearHistory() }
                    .disabled(history.entries.isEmpty)
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 28)
                .help(L("ask.translation.panel.history"))
                .accessibilityIdentifier("ask.translation.panel.history")
            icon(model.pinned ? "pin.fill" : "pin", title: L("ask.translation.panel.pin")) { model.pinned.toggle() }
                .foregroundStyle(model.pinned ? AskTheme.accent : StudioTheme.textTertiary)
                .accessibilityIdentifier("ask.translation.panel.pin")
            Menu {
                Button(L("ask.translation.panel.wordBook") + "  ⌘B", action: model.openWordBook)
                Button(L("ask.translation.panel.keyboard")) { showsShortcuts = true }
                Divider()
                Button(L("ask.translation.panel.settings"), action: model.onSettings)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 28)
                .help(L("ask.translation.panel.more"))
                .accessibilityIdentifier("ask.translation.panel.more")
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .tint(StudioTheme.textTertiary)
        .padding(.leading, 8).padding(.trailing, 8)
        .frame(height: Self.titleHeight)
    }

    private var sourceChip: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: model.source)).font(.system(size: 10))
            Text(model.source.title).font(.system(size: 11))
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 8).frame(height: 22)
        .background(AskTheme.hoverFill, in: Capsule())
        .padding(.trailing, 4)
    }

    static func symbol(for source: AskTranslationPanelSource) -> String {
        switch source {
        case .input: "keyboard"
        case .selection: "character.cursor.ibeam"
        case .screenshot: "camera.viewfinder"
        case .launcher: "command"
        }
    }

    // MARK: Original

    private var original: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.screenshot {
                HStack(spacing: 8) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 52, height: 26).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(L("ask.translation.panel.screenshot", model.screenshotLines)
                        + " · " + L("ask.translation.panel.screenshot.editHint"))
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 4)
            }
            AskComposerTextView(text: $model.text, placeholder: L("ask.translation.panel.placeholder"),
                                contextID: "translation-panel", fontSize: chrome.editorFontSize,
                                maximumHeight: Self.maximumEditorHeight,
                                onSubmit: model.submit, onDismiss: model.escape,
                                onHeightChange: {
                                    editorHeight = min(Self.maximumEditorHeight, max(Self.minimumEditorHeight, $0))
                                })
                .frame(height: editorHeight).padding(.horizontal, 9)
                .accessibilityIdentifier("ask.translation.panel.original")
            HStack(spacing: 2) {
                Text(model.text.isEmpty ? L("ask.translation.panel.hint.translate") + " ↩"
                    : L("ask.translation.panel.characters", model.text.count))
                if model.isDirty, !model.trimmedText.isEmpty, !model.running {
                    HStack(spacing: 4) {
                        Text("↩").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 4).frame(height: 16)
                            .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        Text(L("ask.translation.panel.hint.translate"))
                    }
                    .foregroundStyle(AskTheme.accent).fontWeight(.medium).padding(.leading, 10)
                    .accessibilityIdentifier("ask.translation.panel.pending")
                }
                Spacer()
                if !model.text.isEmpty {
                    icon("speaker.wave.2", title: L("ask.plugin.action.speak")) {
                        model.onSpeak(model.text, model.stack.source ?? "en")
                    }
                    icon("doc.on.doc", title: L("ask.translation.panel.copyOriginal")) { model.onCopy(model.text) }
                    icon("xmark.circle", title: L("ask.translation.panel.clear"), action: model.clear)
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 26)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
                .padding(.horizontal, 14).padding(.top, 6)
        }
    }

    private func icon(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

extension AskTranslationPanelView {
    // MARK: Empty state

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("ask.translation.panel.recent")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            ForEach(Array(history.entries.prefix(Self.recentLimit).enumerated()), id: \.offset) { index, text in
                AskTranslationRecentRow(text: text) {
                    model.chooseHistory(text)
                    model.translate()
                }
                .accessibilityIdentifier("ask.translation.panel.recent.\(index)")
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.panel.recent")
    }

    // MARK: Footer

    private struct Hint: Hashable {
        var key: String
        var title: String
    }

    private var hints: [Hint] {
        let stack = model.stack
        if model.text.isEmpty || model.isDirty {
            return [.init(key: "↩", title: L("ask.translation.panel.hint.translate")),
                    .init(key: "⇥", title: L("ask.translation.panel.hint.language")),
                    .init(key: "⌘P", title: L("ask.translation.panel.hint.pin"))]
        }
        if stack.isLookup, stack.results.first?.card != nil {
            return [.init(key: "↩", title: L("ask.translation.panel.hint.copy")),
                    .init(key: "⌘S", title: L("ask.translation.panel.hint.star")),
                    .init(key: "⌘B", title: L("ask.translation.panel.hint.wordBook"))]
        }
        let count = min(9, max(1, stack.results.count))
        return [.init(key: "↩", title: L("ask.translation.panel.hint.copy")),
                .init(key: "⌥↩", title: L("ask.translation.panel.hint.insert")),
                .init(key: count > 1 ? "⌘1–\(count)" : "⌘1", title: L("ask.translation.panel.hint.copyNth"))]
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            HStack(spacing: 14) {
                if model.pinned {
                    Label(L("ask.translation.panel.pinned"), systemImage: "pin.fill")
                        .labelStyle(.titleAndIcon).foregroundStyle(AskTheme.accent).fontWeight(.medium)
                }
                if let feedback = model.feedback {
                    Label(feedback, systemImage: "checkmark")
                        .foregroundStyle(StudioTheme.textSecondary).fontWeight(.medium)
                        .transition(.opacity)
                        .accessibilityIdentifier("ask.translation.panel.feedback")
                } else {
                    ForEach(hints, id: \.self) { hint in
                        HStack(spacing: 5) {
                            AskTranslationKeyCap(key: hint.key)
                            Text(hint.title)
                        }
                    }
                }
                Spacer(minLength: 0)
                icon("keyboard", title: L("ask.translation.panel.keyboard")) { showsShortcuts.toggle() }
                    .popover(isPresented: $showsShortcuts, arrowEdge: .bottom) { AskTranslationShortcutSheet() }
                    .accessibilityIdentifier("ask.translation.panel.shortcuts")
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: Self.footerHeight - 1)
            .animation(.easeOut(duration: 0.18), value: model.feedback)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.translation.panel.footer")
    }
}

/// A key cap in the footer and the shortcut sheet.
struct AskTranslationKeyCap: View {
    var key: String

    var body: some View {
        Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Every panel shortcut, opened from the footer's keyboard button or the ⋯ menu.
struct AskTranslationShortcutSheet: View {
    static let rows: [(keys: String, title: String)] = [
        ("↩", "ask.translation.panel.hint.translate"),
        ("⇧↩", "ask.translation.panel.shortcut.newline"),
        ("⌘1–9", "ask.translation.panel.hint.copyNth"),
        ("⌥↩", "ask.translation.panel.hint.insert"),
        ("⌘↑ ⌘↓", "ask.translation.panel.shortcut.select"),
        ("⇥ ⇧⇥", "ask.translation.panel.hint.language"),
        ("⌘⇧S", "ask.translation.stack.swap"),
        ("⌘R", "ask.plugin.action.regenerate"),
        ("⌘S", "ask.translation.panel.hint.star"),
        ("⌘B", "ask.translation.panel.hint.wordBook"),
        ("⌘P", "ask.translation.panel.hint.pin"),
        ("esc", "ask.translation.panel.shortcut.close")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("ask.translation.panel.keyboard")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary).padding(.bottom, 2)
            ForEach(Self.rows, id: \.keys) { row in
                HStack(spacing: 10) {
                    AskTranslationKeyCap(key: row.keys).frame(width: 64, alignment: .leading)
                    Text(L(row.title)).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .accessibilityIdentifier("ask.translation.panel.shortcutSheet")
    }
}

private struct AskTranslationRecentRow: View {
    var text: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                Text(text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textPrimary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(hovering ? AskTheme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AskTranslationTitleDragArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        DragView()
    }

    func updateNSView(_: NSView, context _: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
