// swiftlint:disable file_length
import AppKit
import SwiftUI

struct AskLauncherView: View {
    @ObservedObject var model: AskConversationModel
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Moving the panel: a strip along the card's top edge and the bottom bar's empty space.
    var drag: AskWindowDragHandlers?
    @State private var hovering = false

    var body: some View {
        AskComposer(model: model, launcher: true, onDismiss: onDismiss, onHeightChange: onHeightChange)
            .padding(AskMetrics.launcherGutter)
            // Pinned to the panel's top edge: SwiftUI draws new results before the panel
            // takes their height, and centred content would shift the editor and its
            // controls up or down for that frame.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) { if let drag { grip(drag) } }
            .onHover { hovering = $0 }
            .environment(\.askWindowDrag, drag)
            .tint(AskTheme.accent)
            .onChange(of: model.launcherDraft) { _ in model.persistDrafts() }
    }

    /// A strip along the top edge, above the editor's controls, marked by a short
    /// bar while the pointer is over the launcher. Double-click puts it back in the middle.
    /// The strip sits on the card itself: the panel is transparent around the card,
    /// and clicks there fall through to the window below.
    private func grip(_ drag: AskWindowDragHandlers) -> some View {
        AskWindowDragArea(handlers: drag)
            .frame(height: Self.gripHeight)
            .overlay(alignment: .top) {
                Capsule().fill(StudioTheme.textTertiary)
                    .frame(width: 36, height: 4)
                    .padding(.top, 3)
                    .opacity(hovering ? 0.5 : 0)
                    .allowsHitTesting(false)
            }
            .help(L("ask.launcher.drag"))
            .accessibilityIdentifier("ask.launcher.grip")
            .padding(.top, AskMetrics.launcherGutter)
            .padding(.horizontal, AskMetrics.launcherCardCorner)
    }

    /// The card's top points, clear of the editor row's controls (they start 14pt down).
    static let gripHeight: CGFloat = 9
}

/// Included content sits above the editor; switches and actions sit below it.
/// The launcher and the workspace share the same composer. The launcher reads
/// as a search field: the editor is its first row, led by one context token,
/// and its switches sit in a bottom bar under the results.
struct AskComposer: View {
    @ObservedObject var model: AskConversationModel
    var compact: Bool
    var availableWidth: CGFloat?
    var availableHeight: CGFloat?
    var launcher: Bool
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Set by the workspace only: the context ring opens and closes the usage
    /// panel. The launcher has no panel, so it also keeps its fixed footer height.
    var onToggleUsage: (() -> Void)?
    @ObservedObject private var voice: AskVoiceInput
    /// The launcher's keyword mode (`fy` → translate).
    @ObservedObject private var plugins: AskPluginSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var glassOverride
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askWindowDrag) private var windowDrag

    init(model: AskConversationModel, compact: Bool = false, availableWidth: CGFloat? = nil,
         availableHeight: CGFloat? = nil,
         launcher: Bool, onDismiss: @escaping () -> Void = {},
         onHeightChange: @escaping (CGFloat) -> Void = { _ in },
         onToggleUsage: (() -> Void)? = nil) {
        self.model = model
        self.compact = compact
        self.availableWidth = availableWidth
        self.availableHeight = availableHeight
        self.launcher = launcher
        self.onDismiss = onDismiss
        self.onHeightChange = onHeightChange
        self.onToggleUsage = onToggleUsage
        self.voice = model.voiceInput
        self.plugins = model.plugins
        self._voiceShortcut = State(initialValue: model.modelLibrary.settings.activationHotkey)
    }

    private var contextID: String { launcher ? "launcher" : "chat:" + (model.selectedId ?? "new") }
    private var active: Bool { voice.context == contextID && voice.isActive }
    private var listening: Bool { voice.context == contextID && voice.phase == .listening }
    @State private var showingStripPreview = false
    /// Files are dragged over the editor or the card.
    @State private var editorDropTargeted = false
    @State private var cardDropTargeted = false
    private var dropTargeted: Bool { editorDropTargeted || cardDropTargeted }
    private var userAttachments: [AskAttachment] { draft.wrappedValue.attachments ?? [] }
    private var loadingAttachments: Bool { model.isLoadingAttachments(launcher: launcher) }
    @State private var attachmentHeight: CGFloat = 30
    /// Both composers show each included item above the editor.
    private var showsStrip: Bool {
        !userAttachments.isEmpty || loadingAttachments || !chosenTools.isEmpty || !attachedItems.isEmpty
    }
    /// Skills and MCP servers chosen with slash commands, shown as chips.
    private var chosenTools: [AskChosenTool] {
        (draft.wrappedValue.skills ?? []).map { AskChosenTool(kind: .skill, name: $0) }
            + (draft.wrappedValue.mcpServers ?? []).map { AskChosenTool(kind: .mcpServer, name: $0) }
    }
    /// The slash command palette.
    @State private var palette = AskCommandPaletteState()
    @State private var paletteOpen = false
    @State private var slash: AskSlashQuery?
    /// Escape closed the palette for the token starting here; it stays closed until that token goes.
    @State private var dismissedSlash: Int?
    /// Read once when the palette opens; running a command closes it.
    @State private var commandContext: AskCommandContext?
    /// The workspace shows the content that is sent above the editor; the
    /// launcher shows it in its context token.
    private var attachedItems: [AskContextItem] {
        guard !launcher else { return [] }
        return AskAttachmentStrip.contentItems(draft: draft.wrappedValue, screenshotState: screenshotState,
                                               capturing: model.capturingScreenshot)
    }
    /// The launcher's captured app, selection and screenshot; nil when nothing was captured.
    private var contextToken: AskLauncherContext.Token? {
        guard launcher else { return nil }
        return AskLauncherContext.token(draft: draft.wrappedValue, screenshotState: screenshotState,
                                        capturing: model.capturingScreenshot,
                                        restored: model.launcherContextRestored,
                                        collapsed: !draft.wrappedValue.text.isEmpty)
    }
    private var screenshotThumbnail: NSImage? {
        AskAttachmentStrip.thumbnail(dataURL: draft.wrappedValue.screenshot, capturedAt: draft.wrappedValue.capturedAt)
    }
    @State private var contextPanelOpen = false
    @State private var editorHeight: CGFloat = 32
    @State private var measuredWidth: CGFloat = 600
    @State private var supplementalHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    private var layout: AskComposerLayout {
        AskComposerLayout(launcher: launcher, compact: compact, width: availableWidth ?? measuredWidth,
                          availableHeight: availableHeight, paletteOpen: paletteOpen,
                          supplementalHeight: hasSupplementalContent ? max(40, supplementalHeight) : 0)
    }
    private var paletteMaximumHeight: CGFloat? { layout.paletteMaximumHeight(composerHeight: cardHeight) }
    private var compactPalette: Bool {
        !launcher && (layout.usesCompactMetrics
            || AskCommandPaletteView.height(for: palette) > (paletteMaximumHeight ?? .infinity))
    }
    private var paletteHeight: CGFloat {
        AskCommandPaletteView.height(for: palette, compact: compactPalette, maximumHeight: paletteMaximumHeight)
    }
    @State private var voiceShortcut: HotkeyBinding?
    /// Conversations whose queue list is expanded.
    @State private var expandedQueues: Set<String> = []
    private var editingQueued: Bool { !launcher && model.isEditingQueued }

    private var draft: Binding<AskDraft> { launcher ? $model.launcherDraft : $model.draft }
    private var canSend: Bool { launcher ? model.canSendLauncher : model.canSend }
    /// The launcher is the workspace composer summoned by a hotkey: the same
    /// controls and states on a glass card, so it sits on whatever window it floats over.
    private var chrome: AskComposerChrome { .of(launcher: launcher) }
    /// Nil for the opaque workspace card.
    private var glass: AskGlassMaterial? {
        chrome.glass ? glassOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency) : nil
    }
    private func submit() {
        // The send button in keyword mode asks the AI, like ⌘Return.
        if launcher, plugins.isActive, !active { askAIFromPlugin(); return }
        if launcher, showsLauncherSuggestions, !active {
            let disabled = AskLauncherSuggestions.disabled(screenshot: model.screenshotSuggestion(launcher: true))
            let index = AskSuggestion.available(min(suggestionIndex, AskSuggestion.all.count - 1), skipping: disabled)
            if !disabled.contains(index) { pick(AskSuggestion.all[index]) }
            return
        }
        if launcher { model.submitLauncher() } else { model.submitDraft() }
    }
    @State private var suggestionIndex = 0
    /// A local answer for the launcher's text, such as a calculation.
    @State private var quickResults: AskQuickResults?
    /// The tallest the quick results have been since they appeared. The list keeps
    /// that height while typing, so the panel does not shrink and grow with every
    /// keystroke as matches come and go; it resets when the results go away.
    @State private var quickReserve: CGFloat = 0
    /// Quick results show while the launcher's text is all there is to send:
    /// quotes, files or chosen tools mean the text is written for the AI.
    private var showsQuickResults: Bool {
        guard launcher, quickResults != nil, !paletteOpen, pluginDisplay == nil else { return false }
        let value = draft.wrappedValue
        return (value.references ?? []).isEmpty && (value.attachments ?? []).isEmpty
            && (value.skills ?? []).isEmpty && (value.mcpServers ?? []).isEmpty
    }

    /// Writes state only when the results change: the workspace composer and
    /// ordinary questions must not re-render on every keystroke for this.
    private func refreshQuickResults() {
        guard launcher else { return }
        if refreshPlugins() { return }
        let calculator = model.quickCalculatorEnabled, apps = model.quickAppsEnabled
        let next = calculator || apps
            ? AskQuickResults.resolve(text: draft.wrappedValue.text, previous: quickResults,
                                      chinese: AppLocalization.shared.language == .simplifiedChinese,
                                      calculator: calculator, apps: apps ? model.appIndex : nil)
            : nil
        guard next != quickResults else { return }
        quickResults = next
        let reserve = next.map { max(quickReserve, AskQuickResultsView.height(for: $0)) } ?? 0
        if reserve != quickReserve { quickReserve = reserve }
        reportHeight()
    }

    /// Copies a quick result, closing the launcher when asked to, opens an
    /// application, or sends the text to the AI.
    private func runQuickResult(_ row: AskQuickResults.Row, close: Bool) {
        guard let results = quickResults else { return }
        if row == .askAI { model.submitLauncher(); return }
        if let app = results.app(at: row) {
            model.openQuickApp(app)
            onDismiss()
            return
        }
        guard results.isEnabled(row), let value = results.value(of: row) else { return }
        AskQuickResults.copy(value)
        if close {
            model.finishQuickResult()
            onDismiss()
        }
    }

    /// Return runs the highlighted row (copy, or open an application), ⌘Return
    /// asks the AI, Tab writes a calculation's result into the editor to keep
    /// calculating, and the arrows move.
    private func quickResultsKey(_ key: AskCommandKey) -> Bool {
        guard showsQuickResults, !active, var results = quickResults else { return false }
        switch key {
        case .up, .down:
            results.move(key == .up ? -1 : 1)
            quickResults = results
        case .enter:
            runQuickResult(results.highlightedRow, close: true)
        case .commandEnter:
            model.submitLauncher()
        case .tab:
            guard let value = results.value(of: .calculation), !results.stale else { return false }
            draft.wrappedValue.text = value
        case .escape, .optionEnter, .shiftTab, .commandR, .commandD, .commandC, .shiftCommandC, .commandE:
            return false
        }
        return true
    }
    // MARK: - Keyword plugins

    /// Which row in keyword mode is highlighted: 0 the plugin's, 1 "Ask AI".
    @State private var pluginHighlight = 0
    /// Like `quickReserve`: the tallest the plugin's results have been in this keyword mode.
    @State private var pluginReserve: CGFloat = 0

    /// The keyword mode's results, or nil outside it.
    private var pluginDisplay: AskPluginDisplay? {
        guard launcher else { return nil }
        if let plugin = plugins.plugin {
            return AskPluginDisplay(hint: nil, title: plugin.title, symbol: plugin.symbol, optionName: plugin.optionName,
                                    phase: plugins.phase, previous: plugins.previous, partial: plugins.partial,
                                    comparing: plugins.comparing, highlighted: pluginHighlight)
        }
        if let hint = plugins.hint, let plugin = plugins.plugin(for: hint) {
            return AskPluginDisplay(hint: hint, title: plugin.title, symbol: plugin.symbol, phase: .waiting,
                                    highlighted: pluginHighlight)
        }
        return nil
    }

    /// Keyword mode takes the launcher's text first. True when it handled it:
    /// a keyword became a chip (the editor now holds only its argument) or is active.
    private func refreshPlugins() -> Bool {
        let text = draft.wrappedValue.text
        let hadHint = plugins.hint != nil
        if let argument = plugins.detect(in: text) {
            pluginHighlight = 0
            pluginReserve = 0
            draft.wrappedValue.text = argument
            return true
        }
        if plugins.isActive {
            plugins.update(text: text, selection: draft.wrappedValue.sentSelection, language: AppLocalization.shared.language)
            if quickResults != nil { quickResults = nil; quickReserve = 0 }
            reportHeight()
            return true
        }
        // A keyword alone is offered, but Return still asks the AI.
        if plugins.hint != nil, !hadHint, pluginHighlight != 1 { pluginHighlight = 1 }
        return false
    }

    /// ⇥ on a lone keyword, or a click on its row: enter keyword mode.
    private func acceptPluginHint() -> Bool {
        guard plugins.acceptHint() else { return false }
        pluginHighlight = 0
        pluginReserve = 0
        draft.wrappedValue.text = ""
        return true
    }

    /// Return on the plugin's row: run it (or do what its plan offers, like opening
    /// a search), or use its result.
    private func runPluginMain() {
        if pluginDisplay?.hint != nil { _ = acceptPluginHint(); return }
        switch plugins.phase {
        case let .ready(plan):
            // A plan that acts (open a search) must be for the text as typed; it lands within moments.
            if let action = plan.action(for: .enter) {
                if plugins.isPlanCurrent { performPluginAction(action) }
            } else {
                plugins.run()
            }
        case .failed: plugins.run()
        case let .done(_, output): if let action = output.action(for: .enter) { performPluginAction(action) }
        case .waiting, .running: break
        }
    }

    private func performPluginAction(_ action: AskPluginAction) {
        if model.performPluginAction(action) == .close { onDismiss() }
    }

    private func askAIFromPlugin() {
        if let output = plugins.output, let action = output.actions.first(where: { if case .askAI = $0.kind { true } else { false } }) {
            performPluginAction(action)
        } else {
            model.askAIFromPlugin()
        }
    }

    /// Keys in keyword mode, see `docs/design/ask-launcher-keyword-plugins.md` §5.5.
    private func pluginKey(_ key: AskCommandKey) -> Bool {
        guard launcher, !active, let display = pluginDisplay else { return false }
        let selection = draft.wrappedValue.sentSelection, text = draft.wrappedValue.text
        let language = AppLocalization.shared.language
        if display.hint != nil {
            switch key {
            case .up, .down: pluginHighlight = pluginHighlight == 0 ? 1 : 0
            case .tab: return acceptPluginHint()
            case .enter: if pluginHighlight == 0 { return acceptPluginHint() } else { return false }
            default: return false
            }
            return true
        }
        switch key {
        case .up, .down: pluginHighlight = pluginHighlight == 0 ? 1 : 0
        case .tab: _ = plugins.cycle(1, selection: selection, text: text, language: language)
        case .shiftTab: _ = plugins.cycle(-1, selection: selection, text: text, language: language)
        case .enter: if display.asksAI { askAIFromPlugin() } else { runPluginMain() }
        case .commandEnter: askAIFromPlugin()
        case .optionEnter, .commandR, .commandD, .shiftCommandC:
            let shortcut: AskPluginAction.Shortcut = switch key {
            case .optionEnter: .optionEnter
            case .commandR: .commandR
            case .commandD: .commandD
            default: .shiftCommandC
            }
            guard let action = plugins.output?.action(for: shortcut) else { return key != .shiftCommandC }
            // ⇧⌘C copies and stays, like ⌘C.
            if shortcut == .shiftCommandC, case let .copy(text) = action.kind { model.copyPluginText(text) } else { performPluginAction(action) }
        case .commandE:
            let offered: AskPluginAction?
            switch plugins.phase {
            case let .done(_, output): offered = output.action(for: .commandE)
            case let .failed(_, failure): offered = failure.action(for: .commandE)
            default: offered = nil
            }
            guard let offered else { return false }
            performPluginAction(offered)
        case .commandC:
            // With nothing selected in the editor, ⌘C copies the result (or a search's link) and stays.
            let offered: AskPluginAction?
            switch plugins.phase {
            case let .ready(plan): offered = plugins.isPlanCurrent ? plan.action(for: .commandC) : nil
            case let .done(_, output): offered = output.action(for: .commandC)
            case let .failed(_, failure): offered = failure.action(for: .commandC)
            default: offered = nil
            }
            guard let action = offered else { return false }
            if case let .copy(text) = action.kind { model.copyPluginText(text) } else { performPluginAction(action) }
        case .escape: return plugins.cancelRun()
        }
        return true
    }

    /// ⌫ in an empty editor in keyword mode turns the chip back into text.
    private func removeKeyword() -> Bool {
        guard launcher, !active, plugins.isActive else { return false }
        draft.wrappedValue.text = plugins.deactivate() ?? ""
        pluginReserve = 0
        return true
    }

    private var pluginHeight: CGFloat {
        pluginDisplay.map { max(pluginReserve, AskPluginResultsView.height(for: $0)) } ?? 0
    }

    /// The launcher offers its starting points until something is typed. They
    /// stay (disabled) while dictating, so the panel never jumps mid-recording.
    private var showsLauncherSuggestions: Bool {
        launcher && !plugins.isActive && draft.wrappedValue.text.isEmpty && (draft.wrappedValue.references ?? []).isEmpty
            && (draft.wrappedValue.attachments ?? []).isEmpty && !model.isLoadingAttachments(launcher: true) && !paletteOpen
    }

    /// Sends a suggestion as the question, with the screenshot when it asks for one.
    private func pick(_ suggestion: AskSuggestion) {
        // A local draft moves to a vision model first; without one the row cannot be picked.
        if suggestion.screenshot, !model.screenshotSuggestion(launcher: launcher).enabled { return }
        draft.wrappedValue.text = suggestion.title
        if suggestion.screenshot { model.attachScreenshotForSuggestion(launcher: launcher) }
        model.submitLauncher()
    }
    private var sendControl: AskSendControl {
        guard !launcher else { return .send(enabled: canSend) }
        return AskSendControl.resolve(busy: model.isBusy, hasDraft: model.draft.canSend,
                                      canSend: canSend, editingQueued: editingQueued)
    }

    /// Problems to know about or fix, most urgent first. The workspace shows its
    /// send errors in the transcript, next to the answer they belong to.
    private var notices: [AskComposerNotice] {
        AskComposerNotice.resolve(
            sendError: launcher ? model.error : nil,
            voiceError: voice.error,
            attachment: model.attachmentNotice(launcher: launcher),
            screenshot: launcher ? model.launcherScreenshotNotice : model.screenshotNotice
        )
    }
    @State private var noticesExpanded = false
    private var noticeRows: Int {
        AskComposerNotice.visibleCount(total: notices.count, expanded: noticesExpanded)
    }

    private func dismiss(_ kind: AskComposerNotice.Kind) -> (() -> Void)? {
        switch kind {
        case .screenshot:
            return { if launcher { model.launcherScreenshotNotice = nil } else { model.screenshotNotice = nil } }
        case .attachment:
            return { model.dismissAttachmentNotice(launcher: launcher) }
        case .sendError, .voice:
            return nil
        }
    }

    var body: some View {
        card
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AskComposerWidth.self, value: geometry.size.width)
                    .preference(key: AskComposerHeight.self, value: geometry.size.height)
            })
            .onPreferenceChange(AskComposerWidth.self) { width in
                if availableWidth == nil, !launcher, width > 0, abs(measuredWidth - width) > 0.5 {
                    measuredWidth = width
                }
            }
            .onPreferenceChange(AskComposerSupplementalHeight.self) { supplementalHeight = $0 }
            .onPreferenceChange(AskComposerHeight.self) { cardHeight = $0 }
            .onChange(of: editorHeight) { _ in reportHeight() }
            .onChange(of: showsLauncherSuggestions) { _ in reportHeight() }
            .onChange(of: draft.wrappedValue.text) { _ in refreshQuickResults() }
            .onChange(of: pluginDisplay) { display in
                guard launcher else { return }
                // A workflow that only does something closes the launcher when it is done.
                if display?.output?.dismisses == true { model.finishPluginResult(); onDismiss(); return }
                let reserve = display.map { max(pluginReserve, AskPluginResultsView.height(for: $0)) } ?? 0
                if reserve != pluginReserve { pluginReserve = reserve }
                reportHeight()
            }
            .onChange(of: draft.wrappedValue.sentSelection) { _ in if launcher, plugins.isActive { refreshQuickResults() } }
            .onChange(of: noticeRows) { _ in reportHeight() }
            .onChange(of: showsStrip) { _ in reportHeight() }
            .onChange(of: attachmentHeight) { _ in reportHeight() }
            .onPreferenceChange(AskCapturedStripHeight.self) { height in
                if height > 0, abs(attachmentHeight - height) > 0.5 { attachmentHeight = height }
            }
            .onChange(of: paletteOpen) { _ in reportHeight() }
            .onChange(of: palette) { _ in if launcher { reportHeight() } }
            .onChange(of: active) { recording in
                if recording { closePalette(); contextPanelOpen = false }
                reportHeight()
            }
            .onAppear { refreshQuickResults(); reportHeight() }
            .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsDidChange)) { _ in
                voiceShortcut = model.modelLibrary.settings.activationHotkey
            }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if launcher {
                supplementalContent
            } else if hasSupplementalContent {
                ScrollView(.vertical) {
                    supplementalContent
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: AskComposerSupplementalHeight.self, value: geometry.size.height)
                        })
                }
                .frame(height: min(max(1, supplementalHeight), layout.supplementalMaximumHeight))
            }
            if launcher {
                launcherHeader
            } else {
                editorRow
                footer
            }
            if launcher, paletteOpen {
                paletteView
                    .frame(height: AskCommandPaletteView.height(for: palette))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            if launcher, active {
                // Recording takes the results' place at their height, so the panel stays put.
                AskVoicePanel(live: voice.live, listening: listening, height: voicePanelHeight, token: contextToken)
            } else if showsLauncherSuggestions {
                AskLauncherSuggestions(highlighted: $suggestionIndex,
                                       screenshot: model.screenshotSuggestion(launcher: true), onPick: pick)
                    .disabled(active)
            } else if let pluginDisplay {
                AskPluginResultsView(display: pluginDisplay, question: draft.wrappedValue.text,
                                     minimumHeight: pluginReserve,
                                     onMain: runPluginMain, onAction: performPluginAction,
                                     onAskAI: askAIFromPlugin,
                                     onHighlight: { pluginHighlight = $0 })
            } else if showsQuickResults, let quickResults {
                AskQuickResultsView(results: quickResults, question: draft.wrappedValue.text,
                                    minimumHeight: quickReserve, onRun: runQuickResult,
                                    onHighlight: { index in self.quickResults?.highlight(index) })
                    .disabled(active)
            }
            if launcher {
                launcherBar
            }
        }
        .background {
            if let glass {
                chrome.glassBackground(glass)
            } else {
                chrome.fill
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: chrome.corner, style: .continuous))
        .modifier(AskWorkspaceCardDepth(enabled: !launcher, corner: chrome.corner))
        .modifier(AskVoiceBorder(voice: voice, context: contextID, radius: chrome.corner,
                                 idle: chrome.idleBorder(on: glass, increasedContrast: contrast == .increased),
                                 sheen: !launcher))
        .overlay {
            if editingQueued || dropTargeted {
                RoundedRectangle(cornerRadius: chrome.corner, style: .continuous)
                    .strokeBorder(AskTheme.accent, lineWidth: dropTargeted ? 2 : 1.5)
                    .allowsHitTesting(false)
            } else if privateTint {
                // Signed in, a conversation kept on this Mac keeps a quiet private edge.
                RoundedRectangle(cornerRadius: chrome.corner, style: .continuous)
                    .strokeBorder(AskTheme.privateTint.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .askAttachmentDrop(model: model, launcher: launcher, targeted: $cardDropTargeted)
        // The workspace palette floats above the card without moving the transcript.
        .overlay(alignment: .top) {
            if !launcher, paletteOpen {
                // Its height is known, so it sits exactly 8 pt above the card.
                let height = paletteHeight
                paletteView
                    .frame(height: height)
                    .offset(y: -height - 8)
                    .transition(.opacity)
            }
        }
    }

    private var hasSupplementalContent: Bool {
        !notices.isEmpty || (!launcher && !model.queuedMessages.isEmpty) || editingQueued
            || !(draft.wrappedValue.references ?? []).isEmpty || showsStrip
    }

    private var supplementalContent: some View {
        VStack(spacing: 0) {
            if !notices.isEmpty {
                AskComposerNoticeStack(notices: notices, expanded: $noticesExpanded, dismiss: dismiss)
            }
            if !launcher, let id = model.selectedId {
                AskQueueBar(model: model, expanded: Binding(
                    get: { expandedQueues.contains(id) },
                    set: { if $0 { expandedQueues.insert(id) } else { expandedQueues.remove(id) } }
                ))
            }
            if editingQueued, let editing = model.sendQueue.editing {
                AskQueueEditingHeader(index: (model.queuedMessages.firstIndex { $0.id == editing.itemId } ?? 0) + 1,
                                      keepsDraft: editing.stash.canSend)
                    .padding(.horizontal, chrome.horizontalInset)
                    .padding(.top, 10)
            }
            if !(draft.wrappedValue.references ?? []).isEmpty {
                AskReferenceStrip(references: draft.references, locate: { model.referenceLocation = $0 })
                    .padding(.horizontal, chrome.horizontalInset - 4)
                    .padding(.top, 10)
            }
            if showsStrip {
                AskAttachmentStripView(
                    items: attachedItems,
                    screenshot: AskAttachmentStrip.thumbnail(dataURL: draft.wrappedValue.screenshot,
                                                             capturedAt: draft.wrappedValue.capturedAt),
                    onPreview: { showingStripPreview = true },
                    onRemove: remove,
                    attachments: userAttachments,
                    loading: loadingAttachments,
                    onRemoveAttachment: { model.removeAttachment($0, launcher: launcher) },
                    choices: chosenTools,
                    onRemoveChoice: { choice in
                        switch choice.kind {
                        case .skill: model.removeChoice(skill: choice.name, launcher: launcher)
                        case .mcpServer: model.removeChoice(mcpServer: choice.name, launcher: launcher)
                        }
                    },
                    draft: draft,
                    restored: launcher && model.launcherContextRestored,
                    capturing: model.capturing,
                    refreshSource: launcher ? { Task { await model.refreshLauncherContext() } } : nil,
                    sourceRefreshHelp: sourceRefreshHelp,
                    onScreenshotAction: screenshotAction,
                    screenshotCapturing: model.capturingScreenshot
                )
                .disabled(active)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AskCapturedStripHeight.self, value: geometry.size.height)
                })
                .padding(.horizontal, chrome.horizontalInset - 4)
                .padding(.top, 10)
                .popover(isPresented: $showingStripPreview) {
                    AskContextPreview(draft: draft, capturing: model.capturing, warning: model.captureWarning,
                                      recapture: { Task { await model.refreshScreenshot(launcher: launcher) } },
                                      remove: { remove(.screenshot); showingStripPreview = false })
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8),
                           value: attachedItems.map(\.id) + userAttachments.map(\.id) + chosenTools.map(\.id))
            }
        }
    }

    private var paletteView: some View {
        AskCommandPaletteView(state: palette, compact: compactPalette,
                              maximumHeight: launcher ? nil : paletteMaximumHeight,
                              onPick: pickCommand, onHighlight: { palette.highlighted = $0 },
                              onManage: model.onOpenSettings.map { open in { closePalette(); open(.agent) } })
    }

    // MARK: - Slash commands

    private func slashChanged(_ query: AskSlashQuery?, typed: Bool) {
        guard let query, !active else { slash = nil; dismissedSlash = nil; closePalette(); return }
        if dismissedSlash == query.range.location { return }
        dismissedSlash = nil
        guard paletteOpen || typed else { return }
        slash = query
        refreshPalette()
    }

    /// Rebuilds the rows for the token: the commands, a submenu's choices, or
    /// the one command waiting for its argument. Nothing to show closes it.
    private func refreshPalette() {
        guard let slash else { closePalette(); return }
        let context = commandContext ?? model.commandContext(launcher: launcher)
        commandContext = context
        let commands = AskCommandCatalog.commands(context)
        var rows: [AskCommandMatcher.Match] = []
        var parent: AskCommand?
        if let argument = slash.argument {
            guard let command = commands.first(where: { $0.name == slash.name }) else { closePalette(); return }
            switch command.kind {
            case .submenu:
                parent = command
                rows = AskCommandMatcher.filter(AskCommandCatalog.submenu(command.action, context: context), query: argument)
            case .argument:
                var waiting = command
                waiting.detail = argument.isEmpty ? command.trailing : argument
                rows = [AskCommandMatcher.Match(command: waiting, score: 1, highlights: [])]
            default:
                closePalette(); return
            }
        } else {
            let listed = slash.name.isEmpty ? AskCommandCatalog.withRecent(commands, recent: context.recent) : commands
            rows = AskCommandMatcher.filter(listed, query: slash.name)
        }
        guard !rows.isEmpty else { closePalette(); return }
        palette.update(rows: rows, query: slash.argument ?? slash.name, parent: parent)
        withAnimation(.easeOut(duration: 0.15)) { paletteOpen = true }
    }

    private func closePalette() {
        commandContext = nil
        guard paletteOpen else { return }
        withAnimation(.easeOut(duration: 0.12)) { paletteOpen = false }
    }

    private func commandKey(_ key: AskCommandKey) -> Bool {
        guard paletteOpen else { return pluginKey(key) || quickResultsKey(key) }
        switch key {
        case .up: palette.move(-1)
        case .down: palette.move(1)
        case .enter: pickCommand(palette.highlighted)
        case .tab: complete()
        case .escape:
            dismissedSlash = slash?.range.location
            closePalette()
        case .commandEnter, .optionEnter, .shiftTab, .commandR, .commandD, .commandC, .shiftCommandC, .commandE:
            // ⌘Return sends as before, with the palette still open; the rest are the editor's.
            return false
        }
        return true
    }

    /// Replaces the slash token in the draft and keeps the palette following it.
    private func replaceSlash(with replacement: String) {
        guard let current = slash else { return }
        let text = current.replacing(in: draft.wrappedValue.text, with: replacement)
        draft.wrappedValue.text = text
        let caret = current.range.location + (replacement as NSString).length
        slash = AskSlashQuery.parse(text, caret: caret)
    }

    /// Tab writes the highlighted name out, opening its choices or argument.
    private func complete() {
        guard let command = palette.highlightedCommand, command.enabled else { return }
        if palette.parent != nil || command.plain { pickCommand(palette.highlighted); return }
        switch command.kind {
        case .submenu, .argument: replaceSlash(with: "/" + command.name + " ")
        default: replaceSlash(with: "/" + command.name)
        }
        refreshPalette()
    }

    private func pickCommand(_ index: Int) {
        guard palette.rows.indices.contains(index) else { return }
        let command = palette.rows[index].command
        guard command.enabled else { return }
        if palette.parent == nil, command.kind == .submenu || (command.kind == .argument && slash?.argument == nil) {
            replaceSlash(with: "/" + command.name + " ")
            refreshPalette()
            return
        }
        if command.action == .help {
            replaceSlash(with: "/")
            refreshPalette()
            return
        }
        let argument = command.kind == .argument ? slash?.argument : nil
        // An argument command waits until something follows its name.
        if command.kind == .argument, (argument ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return }
        replaceSlash(with: "")
        slash = nil
        closePalette()
        model.runCommand(command, argument: argument, launcher: launcher)
    }

    /// ⌘/ starts a command where the caret is; typing "/" does the same.
    private func startCommand() {
        if paletteOpen { closePalette(); return }
        let text = draft.wrappedValue.text
        let prefix = text.isEmpty || text.last?.isWhitespace == true ? "/" : " /"
        draft.wrappedValue.text = text + prefix
        dismissedSlash = nil
        slashChanged(AskSlashQuery.parse(draft.wrappedValue.text, caret: (draft.wrappedValue.text as NSString).length), typed: true)
    }

    /// Quotes waiting in the draft name what the follow-up is about. The
    /// launcher says what it does besides asking: search and calculate.
    private var placeholder: String {
        if launcher, let plugin = plugins.plugin {
            let lines = draft.wrappedValue.sentSelection.map { AskPresentation.lineCount($0) }
            return plugin.placeholder(selectionLines: lines)
        }
        if launcher { return L("ask.launcher.placeholder") }
        if model.selectedId == nil { return L("ask.input.placeholder") }
        return AskReferenceStrip.placeholder(count: draft.wrappedValue.references?.count ?? 0)
            ?? L("ask.followup.placeholder")
    }

    private var editorField: some View {
        ZStack(alignment: .topLeading) {
            if draft.wrappedValue.text.isEmpty {
                Text(placeholder)
                    .font(.system(size: chrome.editorFontSize))
                    .foregroundStyle(StudioTheme.textTertiary)
                    // Beside the launcher's token a long placeholder truncates rather than wraps.
                    .lineLimit(launcher ? 1 : nil)
                    .padding(.leading, AskComposerTextView.lineFragmentPadding)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
            AskComposerTextView(
                text: draft.text,
                placeholder: placeholder,
                voice: voice,
                contextID: contextID,
                fontSize: chrome.editorFontSize,
                maximumHeight: layout.editorMaximumHeight,
                onSubmit: submit,
                onDismiss: { if editingQueued { model.cancelQueuedEdit() } else { onDismiss() } },
                onHeightChange: { editorHeight = $0 },
                onAttach: { model.addAttachments($0, launcher: launcher) },
                onDropTargetChange: { editorDropTargeted = $0 },
                onSlashQuery: slashChanged,
                onCommandKey: commandKey,
                onEmptyBackspace: launcher ? { removeKeyword() || removeLastContext() } : nil,
                onContextShortcut: launcher ? toggleContextPanel : nil
            )
            .frame(height: min(editorHeight, layout.editorMaximumHeight))
            .disabled(!launcher && model.isLoadingSelection)
        }
    }

    private var editorRow: some View {
        HStack(alignment: .top, spacing: 11) {
            editorField
        }
        .padding(.horizontal, chrome.horizontalInset)
        .padding(.top, layout.editorTopInset)
        .padding(.bottom, layout.editorBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Launcher

    /// The launcher's first row: the context token (the recording dot while
    /// dictating), the editor (the words being recognised), then the microphone
    /// and send buttons, or the elapsed time, cancel and stop while recording.
    private var launcherHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            if active {
                AskVoiceOrb(live: voice.live, listening: listening)
                    .padding(.vertical, 2)
            } else if let token = contextToken {
                AskLauncherContextTokenView(token: token, thumbnail: screenshotThumbnail) {
                    contextPanelOpen.toggle()
                }
                .padding(.vertical, 2)
                .popover(isPresented: $contextPanelOpen, arrowEdge: .bottom) { contextPanel }
            }
            if !active, let keyword = plugins.keyword, let plugin = plugins.plugin {
                AskKeywordChip(title: plugin.title, symbol: plugin.symbol,
                               detail: plugin.chipDetail(for: keyword, language: AppLocalization.shared.language))
                    .padding(.vertical, 2)
            }
            editorField
                // The text sits 2pt high in its view; this centres it on the 34pt buttons.
                .offset(y: 2)
                .opacity(active ? 0 : 1)
                .overlay(alignment: .topLeading) {
                    if active {
                        AskVoiceLiveText(live: voice.live, listening: listening, existing: draft.wrappedValue.text,
                                         fontSize: chrome.editorFontSize)
                            .frame(height: AskMetrics.composerControlHeight)
                    }
                }
            if active {
                AskVoiceElapsed(live: voice.live)
                    .frame(height: AskMetrics.composerControlHeight)
                Button { voice.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: AskMetrics.composerControlHeight, height: AskMetrics.composerControlHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .help(L("ask.voice.cancel"))
                .accessibilityLabel(L("ask.voice.cancel"))
                .accessibilityIdentifier("ask.voice.cancel")
            }
            AskVoiceButton(voice: voice, contextID: contextID, enabled: true, shortcut: voiceShortcut)
                .frame(width: AskMetrics.composerControlHeight, height: AskMetrics.composerControlHeight)
                .accessibilityIdentifier("ask.composer.voice")
            if !active {
                AskSendButton(enabled: canSend, tint: privateTint ? AskTheme.privateTint : AskTheme.accent,
                              prominent: pluginDisplay.map(\.asksAI) ?? AskLauncherContext.sendIsProminent(
                                  quickResults: showsQuickResults && !showsLauncherSuggestions ? quickResults : nil),
                              action: submit)
                    .accessibilityIdentifier("ask.composer.send")
            }
        }
        .padding(.horizontal, chrome.horizontalInset)
        .padding(.top, layout.editorTopInset)
        .padding(.bottom, layout.editorBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Under the results: the model and switches, then what the keys do now.
    private var launcherBar: some View {
        HStack(spacing: 4) {
            composerTools
            Rectangle().fill(AskTheme.separator).frame(width: 1, height: 18).padding(.horizontal, 4)
            contextChips
                .disabled(active)
                .opacity(Self.recordingDim(active))
            // In the launcher the empty space moves the panel; it lays out exactly like the spacer.
            Spacer(minLength: 8)
                .frame(maxHeight: .infinity)
                .background { if let windowDrag { AskWindowDragArea(handlers: windowDrag) } }
            Group {
                if let feedback = model.capturedContentFeedback(launcher: true), !active {
                    AskCapturedContentFeedbackView(feedback: feedback) {
                        model.undoCapturedContent(launcher: true)
                    }
                } else if let feedback = model.commandFeedback, !active {
                    AskComposerFootnote(text: feedback)
                        .transition(.opacity)
                } else {
                    Text(launcherHint)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .layoutPriority(1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.commandFeedback)
        .padding(.leading, chrome.footerLeadingInset)
        .padding(.trailing, 14)
        .frame(height: layout.footerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
        }
        .background {
            AskSlashShortcut(disabled: active, action: startCommand)
        }
    }

    private var launcherHint: String {
        if !active, let pluginDisplay { return AskPluginResultsView.hint(for: pluginDisplay) }
        return AskLauncherContext.hint(voice: active ? voice.phase : .idle,
                                quickResults: showsQuickResults && !showsLauncherSuggestions ? quickResults : nil,
                                hasContext: contextToken != nil)
    }

    /// The launcher's results area: its starting points or quick results.
    private var resultsHeight: CGFloat {
        if showsLauncherSuggestions { return AskLauncherSuggestions.height }
        if pluginDisplay != nil { return pluginHeight }
        if showsQuickResults, let quickResults {
            return max(quickReserve, AskQuickResultsView.height(for: quickResults))
        }
        return 0
    }

    private var voicePanelHeight: CGFloat { max(AskVoicePanel.minimumHeight, resultsHeight) }

    private var contextPanel: some View {
        AskLauncherContextPanel(
            draft: draft, thumbnail: screenshotThumbnail, screenshotState: screenshotState,
            restored: model.launcherContextRestored, capturing: model.capturing,
            screenshotCapturing: model.capturingScreenshot,
            setIncluded: { kind, included in
                if included {
                    model.restoreCapturedContent(kind, launcher: true)
                } else {
                    model.removeCapturedContent(kind, launcher: true)
                }
            },
            toggleScreenshot: screenshotToggleAction,
            fixScreenshot: screenshotFixAction,
            recapture: { Task { await model.refreshScreenshot(launcher: true) } },
            refresh: model.launcherContextRestored ? { Task { await model.refreshLauncherContext() } } : nil,
            refreshTitle: model.launcherReplacementAppName.map { L("ask.context.panel.useApp", $0) }
                ?? L("ask.context.refresh")
        )
    }

    /// Grants access to, or retries, a screenshot that failed.
    private var screenshotFixAction: (() -> Void)? {
        if case .failed = screenshotState { return screenshotAction }
        return nil
    }

    /// ⌫ in the empty launcher takes the captured content off, the screenshot first.
    private func removeLastContext() -> Bool {
        guard launcher, !active, let token = contextToken,
              let kind = AskLauncherContext.backspaceTarget(draft.wrappedValue, screenshot: token.screenshot),
              kind == .screenshot || !model.capturing else { return false }
        model.removeCapturedContent(kind, launcher: true)
        return true
    }

    /// ⌘K opens and closes the context panel.
    private func toggleContextPanel() -> Bool {
        guard launcher, !active, contextToken != nil else { return false }
        contextPanelOpen.toggle()
        return true
    }

    /// Signed in, a conversation kept on this Mac is marked in the private tint; signed
    /// out every conversation is, so nothing needs telling apart.
    private var privateTint: Bool { model.isSignedIn && model.storesLocally(launcher: launcher) }

    private var footer: some View {
        HStack(spacing: 4) {
            composerTools
            // "How to ask" and "what rides along" are separated by a rule.
            if layout.condensedFooter {
                contextMenu
                    .disabled(active)
                    .opacity(Self.recordingDim(active))
                Spacer(minLength: 0)
            } else {
                Rectangle().fill(AskTheme.separator).frame(width: 1, height: 18).padding(.horizontal, 4)
                HStack(spacing: 0) {
                    contextChips
                        .disabled(active)
                        .opacity(Self.recordingDim(active))
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    // Confirms a command in the footer's empty space, inside the card.
                    if let feedback = model.capturedContentFeedback(launcher: launcher), !active {
                        AskCapturedContentFeedbackView(feedback: feedback) {
                            model.undoCapturedContent(launcher: launcher)
                        }
                    } else if let feedback = model.commandFeedback, !active {
                        AskComposerFootnote(text: feedback)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.commandFeedback)
            }
            // Keep the recording label's space when it fits. An idle reservation
            // must not push the context entry or send button outside a narrow card.
            if !layout.condensedFooter {
                ViewThatFits(in: .horizontal) {
                    voiceStatus
                    if !active { Color.clear.frame(width: 0, height: 0) }
                }
                .layoutPriority(active ? 1 : -1)
            }
            if !launcher, !layout.condensedFooter, onToggleUsage != nil, let context = model.usageContext {
                AskContextUsageButton(context: context) { onToggleUsage?() }
            }
            AskVoiceButton(voice: voice, contextID: contextID,
                           enabled: launcher || !model.isLoadingSelection,
                           shortcut: voiceShortcut)
                .frame(width: AskMetrics.composerControlHeight, height: AskMetrics.composerControlHeight)
                .accessibilityIdentifier("ask.composer.voice")
            if editingQueued {
                AskQueueEditActions(canSave: model.draft.canSend, compact: layout.condensedFooter,
                                    onCancel: { model.cancelQueuedEdit() },
                                    onSave: { model.saveQueuedEdit() })
            } else {
                Group {
                    switch sendControl {
                    case .stop: AskStopButton { model.stop() }
                    case let .send(enabled):
                        AskSendButton(enabled: enabled, tint: privateTint ? AskTheme.privateTint : AskTheme.accent,
                                      action: submit)
                    }
                }
                .accessibilityIdentifier("ask.composer.send")
            }
        }
        .padding(.leading, chrome.footerLeadingInset)
        .padding(.trailing, 10)
        .frame(height: layout.footerHeight)
        .frame(maxWidth: .infinity)
        .background {
            AskSlashShortcut(disabled: active || (!launcher && model.isLoadingSelection), action: startCommand)
        }
    }

    /// Attach, where the conversation is kept, and the model: the same in both composers.
    @ViewBuilder private var composerTools: some View {
        AskAttachButton(model: model, launcher: launcher,
                        disabled: active || (!launcher && model.isLoadingSelection))
            .opacity(Self.recordingDim(active))
            .accessibilityIdentifier("ask.composer.attach")
        AskStorageButton(model: model, launcher: launcher)
            .disabled(active)
            .opacity(Self.recordingDim(active))
        AskModelMenu(library: model.modelLibrary, reference: Binding(
            get: { model.modelReference(launcher: launcher) },
            set: { model.selectModel($0, launcher: launcher) }
        ), disabled: active || (!launcher && (model.isBusy || model.isLoadingSelection)),
           hasImage: !launcher && model.hasConversationImages, compact: true,
           condensed: layout.condensedFooter,
           cloudAvailable: model.cloudAvailable(launcher: launcher),
           onManage: model.onOpenSettings.map { open in { open(.models) } },
           effort: $model.reasoningEffort)
        .opacity(Self.recordingDim(active))
        .accessibilityIdentifier("ask.composer.model")
    }

    /// Secondary switches remain reachable without pushing primary actions out
    /// of a narrow footer. They use the same actions as the full-size chips.
    private var contextMenu: some View {
        Menu {
            ForEach(contextItems.filter { $0.kind == .screenshot || $0.kind == .memory }) { item in
                Toggle(isOn: Binding(
                    get: { item.kind == .screenshot ? draft.wrappedValue.includeScreenshot : item.style == .active },
                    set: { _ in
                        if item.kind == .screenshot { screenshotToggleAction?() } else { memoryToggle() }
                    }
                )) {
                    Label(item.kind == .screenshot ? L("ask.screenshot") : item.title, systemImage: item.systemImage)
                }
                .disabled(item.kind == .screenshot && screenshotToggleAction == nil)
            }
            if let onToggleUsage {
                Divider()
                Button(action: onToggleUsage) { Label(L("ask.usage.title"), systemImage: "chart.pie") }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13))
                .frame(width: 26, height: AskMetrics.composerControlHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("ask.context"))
        .accessibilityLabel(L("ask.context"))
        .accessibilityIdentifier("ask.context.menu")
    }

    /// While the microphone is busy the settings and context recede, so the
    /// recording state is the one thing that reads.
    static func recordingDim(_ active: Bool) -> Double { active ? 0.4 : 1 }

    private var sourceRefreshHelp: String {
        if let name = model.launcherReplacementAppName {
            return L("ask.context.refresh.target", name)
        }
        return L("ask.context.refresh.hint")
    }

    private var contextItems: [AskContextItem] {
        let value = draft.wrappedValue
        let newConversation = launcher || model.selectedId == nil
        return AskContextChips.items(
            screenshot: screenshotState,
            source: value.source,
            sourceBundleID: value.sourceBundleID,
            selection: value.selection,
            selectionOff: value.selectionOff == true,
            memory: newConversation ? value.memory : nil,
            memoryOff: model.memorySwitchedOff(launcher: launcher),
            memoryPinned: !newConversation && model.selected?.memory?.isEmpty == false,
            pinnedMemory: newConversation ? nil : model.selected?.memory
        )
    }

    private var screenshotState: AskScreenshotState {
        let value = draft.wrappedValue
        let capability = model.screenshotCapability(launcher: launcher)
        if !capability.canAttach, let reason = capability.hint { return .unavailable(reason: reason) }
        if value.includeScreenshot, value.screenshot == nil, let warning = model.captureWarning {
            return .failed(permission: warning == L("ask.capture.permission"), message: warning)
        }
        return value.includeScreenshot ? .attached : .off
    }

    /// The footer holds only switches. Included content lives in the strip.
    private var contextChips: some View {
        HStack(spacing: AskContextChips.spacing) {
            ForEach(contextItems.filter { $0.kind == .screenshot || $0.kind == .memory }) { item in
                if item.kind == .screenshot {
                    AskIconChip(item: screenshotSwitch(item), action: screenshotToggleAction)
                } else {
                    AskIconChip(item: item, action: memoryToggle)
                }
            }
        }
        .fixedSize()
    }

    private func screenshotSwitch(_ item: AskContextItem) -> AskContextItem {
        var item = item
        if draft.wrappedValue.includeScreenshot {
            item.hint = L("ask.context.screenshot.removeHint")
        }
        return item
    }

    private var screenshotToggleAction: (() -> Void)? {
        if draft.wrappedValue.includeScreenshot { return { remove(.screenshot) } }
        return screenshotAction
    }

    private var screenshotAction: (() -> Void)? {
        switch screenshotState {
        case .unavailable: return nil
        case .attached: return { remove(.screenshot) }
        case .off:
            if model.capturing && draft.wrappedValue.screenshot == nil { return nil }
            return {
                model.restoreCapturedContent(.screenshot, launcher: launcher)
                if draft.wrappedValue.screenshot == nil {
                    Task { await model.refreshScreenshot(launcher: launcher) }
                }
            }
        case let .failed(permission, _):
            if !permission && model.capturing { return nil }
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

    /// Memory switches off and on without being discarded, for a new question
    /// and for a follow-up on the memory pinned to the conversation.
    private func memoryToggle() { model.toggleMemory(launcher: launcher) }

    private func remove(_ kind: AskContextItem.Kind) {
        switch kind {
        case .screenshot: model.removeCapturedContent(.screenshot, launcher: launcher)
        case .selection: model.removeCapturedContent(.selection, launcher: launcher)
        case .source: model.removeCapturedContent(.source, launcher: launcher)
        case .memory: model.toggleMemory(launcher: launcher)
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
        // Confirmations ride in the footer, so only notice rows add height.
        let banners = noticeRows
        let commands = launcher && paletteOpen ? AskCommandPaletteView.height(for: palette) + 10 : 0
        // Recording shows its panel in the results' place, at least as tall as they were.
        let recording = launcher && active
        let quick = !recording && showsQuickResults && !showsLauncherSuggestions
            ? quickResults.map { max(quickReserve, AskQuickResultsView.height(for: $0)) } ?? 0 : 0
        let panel = recording ? voicePanelHeight : 0
        let keyword = !recording ? pluginHeight : 0
        onHeightChange(AskMetrics.launcherHeight(editor: editorHeight, banners: banners,
                                                 suggestions: !recording && showsLauncherSuggestions,
                                                 attachments: showsStrip,
                                                 attachmentHeight: attachmentHeight) + commands + quick + panel + keyword)
    }
}

private struct AskComposerWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AskComposerSupplementalHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AskComposerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AskContextPreview: View {
    @Binding var draft: AskDraft
    var capturing = false
    var warning: String?
    var recapture: () -> Void
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.context.screen.full")).font(.system(size: 13, weight: .semibold))
            Text(L("ask.context.screen.scope")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            if let date = draft.capturedAt { Text(date, style: .time).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary) }
            if let dataURL = draft.screenshot, let image = AskImage.decode(dataURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button(L("ask.capture.refresh"), action: recapture).disabled(capturing)
                    Button(L("ask.remove"), action: remove)
                }
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                    .accessibilityIdentifier("ask.context.screenshot.warning")
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
