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
    /// Set by the workspace only: the context ring opens and closes the usage
    /// panel. The launcher has no panel, so it also keeps its fixed footer height.
    var onToggleUsage: (() -> Void)?
    @ObservedObject private var voice: AskVoiceInput
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var glassOverride
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: AskConversationModel, launcher: Bool, onDismiss: @escaping () -> Void = {},
         onHeightChange: @escaping (CGFloat) -> Void = { _ in },
         onToggleUsage: (() -> Void)? = nil) {
        self.model = model
        self.launcher = launcher
        self.onDismiss = onDismiss
        self.onHeightChange = onHeightChange
        self.onToggleUsage = onToggleUsage
        self.voice = model.voiceInput
        self._voiceShortcut = State(initialValue: model.modelLibrary.settings.activationHotkey)
    }

    private var contextID: String { launcher ? "launcher" : "chat:" + (model.selectedId ?? "new") }
    private var active: Bool { voice.context == contextID && voice.isActive }
    private var listening: Bool { voice.context == contextID && voice.phase == .listening }
    @State private var showingScreenshot = false
    @State private var editorHeight: CGFloat = 32
    @State private var voiceShortcut: HotkeyBinding?

    private var draft: Binding<AskDraft> { launcher ? $model.launcherDraft : $model.draft }
    private var canSend: Bool { launcher ? model.canSendLauncher : model.canSend }
    /// The launcher is the workspace composer summoned by a hotkey: the same
    /// controls and states on a glass card, so it sits on whatever window it floats over.
    private var chrome: AskComposerChrome { .of(launcher: launcher) }
    /// Nil for the opaque workspace card.
    private var glass: AskGlassMaterial? {
        chrome.glass ? glassOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency) : nil
    }
    private func submit() { if launcher { model.submitLauncher() } else { model.submitDraft() } }

    var body: some View {
        VStack(spacing: AskMetrics.bannerSpacing) {
            card
            if let notice = launcher ? model.launcherScreenshotNotice : model.screenshotNotice {
                AskBanner(text: notice, onDismiss: {
                    if launcher { model.launcherScreenshotNotice = nil } else { model.screenshotNotice = nil }
                })
            }
            if let error = voice.error {
                AskBanner(text: error, tone: .warning, systemImage: "mic.slash")
            }
            if launcher, let error = model.error {
                AskBanner(text: error, tone: .warning)
            }
        }
        .onChange(of: editorHeight) { _ in reportHeight() }
        .onChange(of: model.error) { _ in reportHeight() }
        .onChange(of: model.launcherScreenshotNotice) { _ in reportHeight() }
        .onChange(of: model.screenshotNotice) { _ in reportHeight() }
        .onChange(of: voice.error) { _ in reportHeight() }
        .onAppear { reportHeight() }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsDidChange)) { _ in
            voiceShortcut = model.modelLibrary.settings.activationHotkey
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if !(draft.wrappedValue.references ?? []).isEmpty {
                AskReferenceStrip(references: draft.references, locate: { model.referenceLocation = $0 })
            }
            editorRow
            footer
        }
        .background {
            if let glass {
                chrome.glassBackground(glass)
            } else {
                chrome.fill
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: chrome.corner, style: .continuous))
        .modifier(AskVoiceBorder(voice: voice, context: contextID, radius: chrome.corner,
                                 idle: chrome.idleBorder(on: glass, increasedContrast: contrast == .increased)))
    }

    private var editorRow: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.text.isEmpty {
                    Text(L(launcher || model.selectedId == nil ? "ask.input.placeholder" : "ask.followup.placeholder"))
                        .font(.system(size: chrome.editorFontSize))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.leading, AskComposerTextView.lineFragmentPadding)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
                AskComposerTextView(
                    text: draft.text,
                    placeholder: L(launcher || model.selectedId == nil ? "ask.input.placeholder" : "ask.followup.placeholder"),
                    voice: voice,
                    contextID: contextID,
                    fontSize: chrome.editorFontSize,
                    onSubmit: submit,
                    onDismiss: onDismiss,
                    onHeightChange: { editorHeight = $0 }
                )
                .frame(height: editorHeight)
                .disabled(!launcher && model.isLoadingSelection)
            }
        }
        .padding(.horizontal, chrome.horizontalInset)
        .padding(.top, chrome.editorTopInset)
        .padding(.bottom, chrome.editorBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            AskModelMenu(library: model.modelLibrary, reference: Binding(
                get: { model.modelReference(launcher: launcher) },
                set: { model.selectModel($0, launcher: launcher) }
            ), disabled: active || (!launcher && (model.isBusy || model.isLoadingSelection)),
               hasImage: !launcher && model.hasConversationImages, compact: true)
            .opacity(Self.recordingDim(active))
            AskReasoningMenu(library: model.modelLibrary,
                             reference: model.modelReference(launcher: launcher),
                             effort: $model.reasoningEffort,
                             disabled: active || (!launcher && (model.isBusy || model.isLoadingSelection)),
                             compact: true)
                .opacity(Self.recordingDim(active))
            // "How to ask" and "what rides along" are separated by a rule.
            Rectangle().fill(AskTheme.separator).frame(width: 1, height: 16).padding(.horizontal, 4)
            contextChips
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(active)
                .opacity(Self.recordingDim(active))
            voiceStatus
            if !launcher, onToggleUsage != nil, let context = model.usageContext {
                AskContextUsageButton(context: context) { onToggleUsage?() }
            }
            AskVoiceButton(voice: voice, contextID: contextID,
                           enabled: launcher || !model.isLoadingSelection,
                           shortcut: voiceShortcut)
                .frame(width: 32, height: 32)
            AskSendButton(enabled: canSend, action: submit)
        }
        .padding(.leading, chrome.footerLeadingInset)
        .padding(.trailing, 10)
        .frame(height: chrome.footerHeight)
        .frame(maxWidth: .infinity)
    }

    /// While the microphone is busy the settings and context recede, so the
    /// recording state is the one thing that reads.
    static func recordingDim(_ active: Bool) -> Double { active ? 0.4 : 1 }

    private var contextItems: [AskContextItem] {
        let value = draft.wrappedValue
        let newConversation = launcher || model.selectedId == nil
        return AskContextChips.items(
            screenshot: screenshotState,
            source: launcher ? value.source : nil,
            sourceBundleID: value.sourceBundleID,
            selection: value.selection,
            selectionOff: value.selectionOff == true,
            memory: newConversation ? value.memory : nil,
            memoryOff: value.memoryOff == true,
            memoryPinned: !newConversation && model.selected?.memory?.isEmpty == false
        )
    }

    private var screenshotState: AskScreenshotState {
        let value = draft.wrappedValue
        if let reason = model.screenshotCapability(launcher: launcher).hint { return .unavailable(reason: reason) }
        if value.includeScreenshot, value.screenshot == nil, let warning = model.captureWarning {
            return .failed(permission: warning == L("ask.capture.permission"), message: warning)
        }
        return value.includeScreenshot ? .attached : .off
    }

    /// Icon chips, widest layout that fits first. Screenshot and source stay
    /// visible; selection and memory fold into "+N" from the right.
    private var contextChips: some View {
        let items = contextItems
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(AskContextChips.layouts(items).enumerated()), id: \.offset) { _, layout in
                HStack(spacing: AskContextChips.spacing) {
                    ForEach(layout.shown) { chip($0) }
                    if !layout.hidden.isEmpty {
                        AskOverflowChip(hidden: layout.hidden, onRemove: remove)
                    }
                    if model.capturing { ProgressView().controlSize(.small) }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func chip(_ item: AskContextItem) -> some View {
        switch item.kind {
        case .screenshot:
            AskIconChip(item: item, action: screenshotAction, onRemove: { remove(.screenshot) })
                .popover(isPresented: $showingScreenshot) {
                    AskContextPreview(draft: draft,
                                      recapture: { Task { await model.refreshScreenshot(launcher: launcher) } })
                }
        case .selection:
            // The hover card previews the text; a click switches it on or off.
            AskIconChip(item: item, action: selectionToggle)
        case .source:
            AskIconChip(item: item)
        case .memory:
            AskIconChip(item: item, action: memoryToggle)
        }
    }

    private var screenshotAction: (() -> Void)? {
        switch screenshotState {
        case .unavailable: return nil
        case .attached: return { showingScreenshot = true }
        case .off:
            return {
                draft.wrappedValue.includeScreenshot = true
                if draft.wrappedValue.screenshot == nil {
                    Task { await model.refreshScreenshot(launcher: launcher) }
                }
            }
        case let .failed(permission, _):
            return {
                if permission {
                    // Registers the app in the list first, otherwise the pane shows no Typeflux entry.
                    AskContextCapture.requestScreenCaptureAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    Task { await model.refreshScreenshot(launcher: launcher) }
                }
            }
        }
    }

    /// Memory pinned to an existing conversation is read-only; a new question's
    /// memory switches off and on without being discarded.
    private var memoryToggle: (() -> Void)? {
        guard launcher || model.selectedId == nil else { return nil }
        return { draft.wrappedValue.memoryOff = draft.wrappedValue.memoryOff == true ? nil : true }
    }

    private func selectionToggle() {
        draft.wrappedValue.selectionOff = draft.wrappedValue.selectionOff == true ? nil : true
    }

    private func remove(_ kind: AskContextItem.Kind) {
        switch kind {
        case .screenshot: draft.wrappedValue.includeScreenshot = false
        case .selection: draft.wrappedValue.selectionOff = true
        case .memory: draft.wrappedValue.memoryOff = true
        case .source: break
        }
    }

    private var voiceStatus: some View {
        // Reserve the largest localized label even while idle, so actions never move.
        HStack(spacing: 7) {
            if listening { AskWaveform() }
            ZStack(alignment: .trailing) {
                Text(L("ask.voice.listening")).hidden()
                Text(L("ask.voice.transcribing")).hidden()
                if active { Text(L(listening ? "ask.voice.listening" : "ask.voice.transcribing")) }
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(listening ? AskTheme.accent : StudioTheme.textSecondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? L(listening ? "ask.voice.listening" : "ask.voice.transcribing") : "")
        .accessibilityHidden(!active)
    }

    private func reportHeight() {
        var banners = voice.error == nil ? 0 : 1
        if (launcher ? model.launcherScreenshotNotice : model.screenshotNotice) != nil { banners += 1 }
        if launcher, model.error != nil { banners += 1 }
        onHeightChange(AskMetrics.launcherHeight(editor: editorHeight, banners: banners))
    }
}

private struct AskContextPreview: View {
    @Binding var draft: AskDraft
    var recapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.context")).font(.system(size: 13, weight: .semibold))
            if let source = draft.source { Text(source).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2) }
            if let date = draft.capturedAt { Text(date, style: .time).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary) }
            if let dataURL = draft.screenshot, let image = AskImage.decode(dataURL) {
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
