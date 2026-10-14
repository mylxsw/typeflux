import AppKit
import SwiftUI

/// Native panel chrome around the same language bar, word card and services as `fy`.
struct AskTranslationPanelView: View {
    @ObservedObject var model: AskTranslationPanelModel
    @ObservedObject var history: AskTranslationHistory
    var height: CGFloat
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @State private var editorHeight: CGFloat = 48
    @State private var measuredChromeHeight: CGFloat?
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var chrome: AskComposerChrome {
        AskTranslationAppearance.chrome(style: style, increasedContrast: contrast == .increased)
    }

    private var material: AskGlassMaterial {
        AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style)
    }

    static func chromeHeight(screenshot: Bool) -> CGFloat {
        screenshot ? 214 : 182
    }

    var body: some View {
        VStack(spacing: 8) {
            titleBar
                .translationContentHeight(.title)
            original
                .padding(.horizontal, 10)
                .translationContentHeight(.original)
            AskTranslationStackView(stack: model.stack, original: model.output?.original ?? model.text,
                                    actions: model.output?.actions ?? [], selected: model.output?.selectedItem ?? 0,
                                    starred: model.output?.starred == true, running: model.running,
                                    viewportHeight: max(
                                        42,
                                        height - (measuredChromeHeight
                                            ?? (Self.chromeHeight(screenshot: model.screenshot != nil)
                                                + editorHeight - 48 + (model.notice == nil ? 0 : 24)))
                                    ),
                                    defaults: model.settings.defaults,
                                    onAction: model.perform, onSelect: model.select)
                .padding(.horizontal, 10)
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(StudioTheme.danger)
                    .lineLimit(2).padding(.horizontal, 12)
                    .translationContentHeight(.notice)
            }
            footer
                .translationContentHeight(.footer)
        }
        .onPreferenceChange(AskTranslationContentHeight.self) { heights in
            let required: [AskTranslationContentHeight.Part] = [.title, .original, .languages, .results, .footer]
            guard required.allSatisfy({ heights[$0] != nil }) else { return }
            let chromeParts: [AskTranslationContentHeight.Part] = [.title, .original, .notice, .footer]
            let chrome = chromeParts.reduce(CGFloat.zero) { $0 + (heights[$1] ?? 0) }
                + (heights[.notice] == nil ? 24 : 32) + AskMetrics.launcherGutter * 2
            measuredChromeHeight = chrome
            onContentHeightChange(chrome + (heights[.languages] ?? 0) + (heights[.results] ?? 0) + 8)
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

    private var titleBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "character.bubble.fill").font(.system(size: 11))
                    .foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                Text(L("ask.plugin.translate.title")).font(.system(size: 13, weight: .semibold))
                Text(model.source.title).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 0)
            }
            .background(AskTranslationTitleDragArea())
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
                .help(L("ask.translation.panel.history"))
                .accessibilityIdentifier("ask.translation.panel.history")
            icon("gearshape", title: L("ask.translation.panel.settings"), action: model.onSettings)
            icon(model.pinned ? "pin.fill" : "pin", title: L("ask.translation.panel.pin")) { model.pinned.toggle() }
                .foregroundStyle(model.pinned ? AskTheme.accent : StudioTheme.textTertiary)
                .accessibilityIdentifier("ask.translation.panel.pin")
        }
        .foregroundStyle(StudioTheme.textPrimary).padding(.leading, 14).padding(.trailing, 10).padding(.top, 9)
    }

    private var original: some View {
        VStack(spacing: 0) {
            if let image = model.screenshot {
                HStack(spacing: 6) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 22).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(L("ask.translation.panel.screenshot", model.screenshotLines)
                        + " · " + L("ask.translation.panel.screenshot.editHint"))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 11).padding(.top, 8)
            }
            AskComposerTextView(text: $model.text, placeholder: L("ask.translation.panel.placeholder"),
                                contextID: "translation-panel", fontSize: chrome.editorFontSize, maximumHeight: 96,
                                onSubmit: model.submit, onDismiss: model.escape,
                                onHeightChange: { editorHeight = min(96, max(48, $0)) })
                .frame(height: editorHeight).padding(.horizontal, 6).padding(.top, 5)
                .accessibilityIdentifier("ask.translation.panel.original")
            HStack(spacing: 2) {
                Text(model.stack.source.map { AskTranslationLanguages.name($0, in: model.interface) }
                    ?? L("ask.translation.stack.detect"))
                Text("·")
                Text(L("ask.translation.panel.characters", model.text.count))
                Spacer()
                icon("speaker.wave.2", title: L("ask.plugin.action.speak")) {
                    model.onSpeak(model.text, model.stack.source ?? "en")
                }.disabled(model.text.isEmpty)
                icon("doc.on.doc", title: L("ask.translation.panel.copyOriginal")) { model.onCopy(model.text) }
                    .disabled(model.text.isEmpty)
                icon("xmark.circle", title: L("ask.translation.panel.clear"), action: model.clear)
                    .disabled(model.text.isEmpty)
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.leading, 11).padding(.trailing, 5).padding(.bottom, 5)
        }
        .background(AskTranslationAppearance.cardFill(style: style), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(
            AskTranslationAppearance.border(style: style),
            lineWidth: 1
        ) }
    }

    private var footer: some View {
        Text(L("ask.translation.panel.hint"))
            .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(AskTheme.hoverFill)
            .accessibilityIdentifier("ask.translation.panel.footer")
    }

    private func icon(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
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
