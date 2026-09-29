import AppKit
import SwiftUI

struct AskLauncherView: View {
    @ObservedObject var model: AskConversationModel
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        AskComposer(model: model, launcher: true, onDismiss: onDismiss, onHeightChange: onHeightChange)
            .padding(AskMetrics.launcherGutter)
            .tint(AskTheme.accent)
            .onChange(of: model.launcherDraft) { _ in model.persistDrafts() }
    }
}

/// Two layers: the editor row carries the question, the footer carries context
/// and actions. The launcher and the workspace share it so both behave the same.
struct AskComposer: View {
    @ObservedObject var model: AskConversationModel
    var launcher: Bool
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @ObservedObject private var voice: AskVoiceInput

    init(model: AskConversationModel, launcher: Bool, onDismiss: @escaping () -> Void = {},
         onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.launcher = launcher
        self.onDismiss = onDismiss
        self.onHeightChange = onHeightChange
        self.voice = model.voiceInput
    }

    private var contextID: String { launcher ? "launcher" : "chat:" + (model.selectedId ?? "new") }
    private var active: Bool { voice.context == contextID && voice.isActive }
    private var listening: Bool { voice.context == contextID && voice.phase == .listening }
    @State private var showingScreenshot = false
    @State private var showingSelection = false
    @State private var editorHeight: CGFloat = 32

    private var draft: Binding<AskDraft> { launcher ? $model.launcherDraft : $model.draft }
    private var canSend: Bool { launcher ? model.canSendLauncher : model.canSend }
    private var corner: CGFloat { launcher ? AskMetrics.launcherCorner : AskMetrics.composerCorner }
    private var editorFontSize: CGFloat { launcher ? 15.5 : 14 }
    private func submit() { if launcher { model.submitLauncher() } else { model.submitDraft() } }

    var body: some View {
        VStack(spacing: AskMetrics.bannerSpacing) {
            card
            if let error = voice.error {
                AskBanner(text: error, tone: .warning, systemImage: "mic.slash")
            }
            if launcher, let error = model.error {
                AskBanner(text: error, tone: .warning)
            }
        }
        .onChange(of: editorHeight) { _ in reportHeight() }
        .onChange(of: model.error) { _ in reportHeight() }
        .onChange(of: voice.error) { _ in reportHeight() }
        .onAppear { reportHeight() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            editorRow
            footer
        }
        .background(AskTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .modifier(AskVoiceBorder(voice: voice, context: contextID, radius: corner))
    }

    private var editorRow: some View {
        HStack(alignment: .top, spacing: 11) {
            if launcher {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AskTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(AskTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
            }
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.text.isEmpty {
                    Text(L(launcher || model.selectedId == nil ? "ask.input.placeholder" : "ask.followup.placeholder"))
                        .font(.system(size: editorFontSize))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.leading, 2)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
                AskComposerTextView(
                    text: draft.text,
                    placeholder: L(launcher || model.selectedId == nil ? "ask.input.placeholder" : "ask.followup.placeholder"),
                    voice: voice,
                    contextID: contextID,
                    fontSize: editorFontSize,
                    onSubmit: submit,
                    onDismiss: onDismiss,
                    onHeightChange: { editorHeight = $0 }
                )
                .frame(height: editorHeight)
                .disabled(!launcher && model.isLoadingSelection)
            }
        }
        .padding(.horizontal, launcher ? 17 : 15)
        .padding(.top, AskMetrics.editorTopInset)
        .padding(.bottom, AskMetrics.editorBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.surface)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if active { voiceStatus } else {
                AskModelMenu(library: model.modelLibrary, reference: Binding(
                    get: { model.modelReference(launcher: launcher) },
                    set: { draft.wrappedValue.modelRef = $0 }
                ), disabled: !launcher && (model.isBusy || model.isLoadingSelection),
                   hasImage: model.requiresVision(launcher: launcher))
                contextChips
            }
            Spacer(minLength: 6)
            if !active {
                trailingHint
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            AskSendButton(enabled: canSend, action: submit)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: AskMetrics.footerHeight)
        .frame(maxWidth: .infinity)
        .background(AskTheme.raisedSurface)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
    }

    @ViewBuilder private var contextChips: some View {
        screenshotChip
            .popover(isPresented: $showingScreenshot) {
                AskContextPreview(draft: draft, showsSelection: false,
                                  recapture: { Task { await model.refreshScreenshot(launcher: launcher) } })
            }
        if draft.wrappedValue.selection != nil {
            selectionChip
                .popover(isPresented: $showingSelection) {
                    AskContextPreview(draft: draft, showsSelection: true,
                                      recapture: { Task { await model.refreshScreenshot(launcher: launcher) } })
                }
        }
        if launcher, draft.wrappedValue.selection == nil, let source = draft.wrappedValue.source, !source.isEmpty {
            AskChip(title: source, systemImage: "macwindow")
        }
        if model.capturing { ProgressView().controlSize(.small) }
    }

    private var screenshotChip: AskChip {
        let value = draft.wrappedValue
        if value.includeScreenshot, value.screenshot == nil, let warning = model.captureWarning {
            let permission = warning == L("ask.capture.permission")
            return AskChip(
                title: permission ? L("ask.capture.settings") : L("ask.capture.retry"),
                systemImage: "exclamationmark.triangle.fill",
                style: .warning,
                action: {
                    if permission {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await model.refreshScreenshot(launcher: launcher) }
                    }
                },
                help: warning
            )
        }
        if value.includeScreenshot {
            return AskChip(
                title: L("ask.screenshot"),
                systemImage: "camera.viewfinder",
                style: .active,
                action: { showingScreenshot = true },
                onRemove: { draft.wrappedValue.includeScreenshot = false },
                help: L("ask.preview")
            )
        }
        return AskChip(
            title: L("ask.screenshot"),
            systemImage: "camera.viewfinder",
            style: value.screenshot == nil ? .dashed : .neutral,
            action: {
                draft.wrappedValue.includeScreenshot = true
                if draft.wrappedValue.screenshot == nil {
                    Task { await model.refreshScreenshot(launcher: launcher) }
                }
            }
        )
    }

    private var selectionChip: AskChip {
        AskChip(
            title: L("ask.selection.lines", AskPresentation.lineCount(draft.wrappedValue.selection ?? "")),
            systemImage: "text.cursor",
            style: .active,
            action: { showingSelection = true },
            onRemove: { draft.wrappedValue.selection = nil },
            help: L("ask.selection")
        )
    }

    private var voiceStatus: some View {
        HStack(spacing: 8) {
            if listening {
                AskWaveform()
                Text(L("ask.voice.listening"))
            } else {
                ProgressView().controlSize(.mini)
                Text(L("ask.voice.transcribing"))
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(listening ? AskTheme.accent : AskTheme.accent.opacity(0.75))
        .lineLimit(1)
    }

    @ViewBuilder private var trailingHint: some View {
        if draft.wrappedValue.canSend {
            HStack(spacing: 5) {
                AskKeyCap(symbol: "return")
                Text(L("ask.send"))
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "mic").font(.system(size: 11))
                Text(L("ask.voice.hold"))
            }
        }
    }

    private func reportHeight() {
        var banners = voice.error == nil ? 0 : 1
        if launcher, model.error != nil { banners += 1 }
        onHeightChange(AskMetrics.launcherHeight(editor: editorHeight, banners: banners))
    }
}

private struct AskContextPreview: View {
    @Binding var draft: AskDraft
    var showsSelection: Bool
    var recapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.context")).font(.system(size: 13, weight: .semibold))
            if let source = draft.source { Text(source).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2) }
            if let date = draft.capturedAt { Text(date, style: .time).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary) }
            if showsSelection, let text = draft.selection {
                ScrollView {
                    Text(text).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Button(L("ask.selection.remove")) { draft.selection = nil }
            }
            if !showsSelection, let dataURL = draft.screenshot, let image = AskImage.decode(dataURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button(L("ask.capture.refresh"), action: recapture)
                    Button(L("ask.remove")) { draft.screenshot = nil; draft.includeScreenshot = false }
                }
            }
            Text(L("ask.context.notice")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
        }
        .padding(18)
        .frame(width: 400)
    }
}

enum AskImage {
    static func decode(_ value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}
