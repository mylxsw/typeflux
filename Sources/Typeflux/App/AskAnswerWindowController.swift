import AppKit
import SwiftUI

final class AskAnswerWindowController {
    private final class AskAnswerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    fileprivate final class Model: ObservableObject {
        @Published var title: String = ""
        @Published var question: String = ""
        @Published var selectedText: String = ""
        @Published var answerMarkdown: String = ""
        @Published var onDismissRequested: (() -> Void)?
        @Published var onCopyRequested: (() -> Void)?
    }

    private let clipboard: ClipboardService
    private let model = Model()
    private var window: NSPanel?

    init(clipboard: ClipboardService) {
        self.clipboard = clipboard
    }

    func show(title: String, question: String, selectedText: String?, answerMarkdown: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(title: title, question: question, selectedText: selectedText, answerMarkdown: answerMarkdown)
            }
            return
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAnswer = answerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAnswer.isEmpty else { return }

        ensureWindow()
        model.title = title
        model.question = trimmedQuestion
        model.selectedText = trimmedSelectedText
        model.answerMarkdown = trimmedAnswer
        model.onDismissRequested = { [weak self] in self?.dismiss() }
        model.onCopyRequested = { [weak self] in
            self?.clipboard.write(text: trimmedAnswer)
        }

        centerWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
            return
        }
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let rootView = AskAnswerWindowView(model: model)
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = AskAnswerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        window = panel
    }

    private func centerWindow() {
        guard let window else { return }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }
}

private struct AskAnswerWindowView: View {
    @ObservedObject var model: AskAnswerWindowController.Model

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.982, blue: 0.972),
                    Color(red: 0.972, green: 0.968, blue: 0.955)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 26) {
                header
                promptSection
                answerSection
            }
            .padding(.horizontal, 34)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .frame(width: 1120, height: 760)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .background(Color.clear)
    }

    private var header: some View {
        HStack {
            Spacer()

            Text(model.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.92))

            Spacer()

            Button(action: { model.onDismissRequested?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.5))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.44, green: 0.53, blue: 0.96))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 10) {
                    Text(model.question)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !model.selectedText.isEmpty {
                        Text(model.selectedText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.56))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Color.black.opacity(0.14))
                                    .frame(width: 3)
                            }
                    }
                }

                Button(action: { model.onCopyRequested?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.52))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L("common.copy"))
            }
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("workflow.ask.answerSectionTitle"), systemImage: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.86))

                Spacer()

                Button(action: { model.onCopyRequested?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L("common.copy"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()
                .overlay(Color.black.opacity(0.06))

            ScrollView(showsIndicators: true) {
                MarkdownRenderedText(markdown: model.answerMarkdown)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct MarkdownRenderedText: View {
    let markdown: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color.black.opacity(0.9))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
