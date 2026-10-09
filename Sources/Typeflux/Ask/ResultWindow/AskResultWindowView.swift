import SwiftUI

/// A result in its own window: a title bar with the source and the star, the original
/// folded away, the Markdown, and the actions along the bottom.
struct AskResultWindowView: View {
    @ObservedObject var document: AskResultDocument
    var onClose: () -> Void

    static let readingWidth: CGFloat = 680
    /// Room for the traffic lights at the left of the title bar.
    static let trafficLightClearance: CGFloat = 78
    private static let bottomID = "ask.result.bottom"

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if !document.input.isEmpty { original }
            content
            toolbar
        }
        .background(AskWordBookBackground(fill: StudioTheme.shellSurface))
        .overlay(alignment: .bottom) { noticeView }
        .background(shortcuts)
        .accessibilityIdentifier("ask.result.window")
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.trafficLightClearance)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(document.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if document.isStreaming {
                iconButton("stop.fill", help: L("ask.result.stop") + " ⌘.", active: false, action: document.stop)
                    .accessibilityIdentifier("ask.result.stop")
            }
            iconButton(document.pinned ? "pin.fill" : "pin",
                       help: L(document.pinned ? "ask.result.unpin" : "ask.result.pin"),
                       active: document.pinned) { document.pinned.toggle() }
                .accessibilityIdentifier("ask.result.pin")
            starButton
            iconButton("note.text", help: L("ask.notes.open") + " ⌘B", active: false, action: document.openNotes)
                .accessibilityIdentifier("ask.result.notes")
        }
        .padding(.trailing, 10)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }

    private var subtitle: String {
        let time = document.isStreaming ? L("ask.result.streaming")
            : document.updatedAt.formatted(date: .omitted, time: .shortened)
        return ([document.model].compactMap { $0 } + [time]).map { "· " + $0 }.joined(separator: " ")
    }

    private var starButton: some View {
        let saved = document.noteID != nil
        let pending = document.savesWhenDone
        return Button(action: document.toggleNote) {
            Image(systemName: saved || pending ? "star.fill" : "star").font(.system(size: 12.5))
                .foregroundStyle(saved || pending ? AskWordBookStyle.star : StudioTheme.textSecondary)
                .opacity(pending ? 0.55 : 1)
                .frame(width: 28, height: 26)
                .background(saved || pending ? AskWordBookStyle.star.opacity(0.16) : StudioTheme.controlSurface,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(saved ? "ask.notes.unsave" : "ask.notes.save") + " ⌘S")
        .accessibilityLabel(L(saved ? "ask.notes.unsave" : "ask.notes.save"))
        .accessibilityIdentifier("ask.result.star")
    }

    private func iconButton(_ symbol: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(active ? StudioTheme.accent : StudioTheme.textSecondary)
                .frame(width: 28, height: 26)
                .background(active ? StudioTheme.accent.opacity(0.16) : StudioTheme.controlSurface,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Original and text

    private var original: some View {
        DisclosureGroup {
            ScrollView(.vertical) {
                Text(document.input).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 110)
        } label: {
            Text(L("ask.result.original") + " · " + AskNote.oneLine(document.input))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }

    private var content: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if !document.body.isEmpty || document.isStreaming {
                        AskTranscriptText(text: document.isStreaming ? document.body + AskPluginResultsView.caret
                            : document.body)
                            .opacity(document.dimmed ? 0.45 : 1)
                    }
                    if case let .failed(message) = document.state {
                        Text(message).font(.system(size: 13.5)).foregroundStyle(StudioTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26).padding(.vertical, 18)
            }
            .onChange(of: document.body) { _ in
                if document.isStreaming { reader.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton(L("ask.plugin.action.copy"), symbol: "doc.on.doc", key: nil, primary: true,
                       enabled: !document.body.isEmpty, action: document.copy)
            toolButton(L("ask.plugin.action.copyRich"), symbol: "doc.richtext", key: "⇧⌘C", primary: false,
                       enabled: !document.body.isEmpty, action: document.copyRich)
            if document.sourceBundleID != nil {
                toolButton(L("ask.result.insert", document.sourceApp ?? L("ask.result.sourceApp")),
                           symbol: "arrow.down.to.line", key: "⌥↩", primary: false, enabled: document.canInsert,
                           action: document.insert)
                    .help(document.canInsert || document.isStreaming ? "" : L("ask.result.insert.unavailable"))
            }
            if document.fromNote {
                toolButton(L("ask.result.revealNote"), symbol: "note.text", key: "⌘B", primary: false, enabled: true,
                           action: document.openNotes)
            } else {
                toolButton(L("ask.plugin.action.regenerate"), symbol: "arrow.clockwise", key: "⌘R", primary: false,
                           enabled: document.canRegenerate, action: document.regenerate)
            }
            Spacer(minLength: 8)
            toolButton(L("ask.result.askAI"), symbol: "bubble.left", key: "⌘↩", primary: false,
                       enabled: !document.isStreaming && !document.body.isEmpty, action: document.askAI)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .overlay(alignment: .top) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }

    private func toolButton(_ title: String, symbol: String, key: String?, primary: Bool, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12)).lineLimit(1)
                if let key { Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
            }
            .foregroundStyle(primary ? AskTheme.accent : StudioTheme.textSecondary)
            .padding(.horizontal, 9).frame(height: 26)
            .background(primary ? AskTheme.accent.opacity(0.16) : StudioTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var noticeView: some View {
        if let notice = document.notice {
            Text(notice).font(.system(size: 12)).foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, 10).frame(height: 26)
                .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.border))
                .padding(.bottom, 56)
                .transition(.opacity)
                .accessibilityIdentifier("ask.result.notice")
        }
    }

    /// Keys without buttons of their own; ⌘C stays the text view's, for a selection.
    private var shortcuts: some View {
        ZStack {
            Button("") { document.toggleNote() }.keyboardShortcut("s")
            Button("") { document.regenerate() }.keyboardShortcut("r")
            Button("") { document.copyRich() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { document.insert() }.keyboardShortcut(.return, modifiers: .option)
            Button("") { if !document.isStreaming { document.askAI() } }.keyboardShortcut(.return, modifiers: .command)
            Button("") { document.openNotes() }.keyboardShortcut("b")
            Button("") { document.stop() }.keyboardShortcut(".")
            Button("") { onClose() }.keyboardShortcut("w")
            Button("") { onClose() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}
