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
    @State private var showingNumberHints = false

    var body: some View {
        GeometryReader { geometry in
            AskComposer(model: model, availableHeight: geometry.size.height, launcher: true,
                        onDismiss: onDismiss, onHeightChange: onHeightChange)
        }
            .padding(AskMetrics.launcherGutter)
            // Pinned to the panel's top edge: SwiftUI draws new results before the panel
            // takes their height, and centred content would shift the editor and its
            // controls up or down for that frame.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) { if let drag { grip(drag) } }
            .onHover { hovering = $0 }
            .environment(\.askWindowDrag, drag)
            .environment(\.askLauncherNumberHints, showingNumberHints)
            .background(AskLauncherCommandMonitor { showingNumberHints = $0 })
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
/// as a search field: the editor is its first row,
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
    @Environment(\.interfaceStyle) private var interfaceStyle

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
        self._quickSearch = StateObject(wrappedValue: launcher ? model.quickSearch : AskQuickSearchSession())
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
    /// launcher inspects it from the bottom bar.
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
    private var chrome: AskComposerChrome { .of(launcher: launcher, style: interfaceStyle) }
    /// Nil for the opaque workspace card.
    private var glass: AskGlassMaterial? {
        chrome.glass ? glassOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency,
                                                                 style: interfaceStyle) : nil
    }
    private func submit() {
        if model.consumeModeCommand(launcher: launcher) { closePalette(); return }
        // Submitting in keyword mode asks the AI, like ⌘Return, when there is something to ask.
        if launcher, plugins.isActive, !active {
            if pluginDisplay?.offersAskAI != false { askAIFromPlugin() }
            return
        }
        if launcher, showsLauncherSuggestions, !active, let item = highlightedHomeItem {
            pick(item)
            return
        }
        if launcher { model.submitLauncher() } else { model.submitDraft() }
    }
    @State private var suggestionIndex = 0
    /// A local answer for the launcher's text, such as a calculation.
    @State private var searchVisible = false
    @StateObject private var quickSearch: AskQuickSearchSession
    private var quickResults: AskQuickResults? {
        get { quickSearch.results }
        nonmutating set { quickSearch.results = newValue }
    }
    private var presentedQuickResults: AskQuickResults? { quickSearch.presentation }
    private var quickResultsArePending: Bool {
        quickSearch.pendingResults != nil || !quickSearch.isCurrent(text: draft.wrappedValue.text)
    }
    /// The tallest the quick results have been since they appeared. The list keeps
    /// that height while typing, so the panel does not shrink and grow with every
    /// keystroke as matches come and go; it resets when the results go away and
    /// settles to the rows once typing pauses (`AskLauncherHeightReserve`).
    @State private var quickReserve: CGFloat = 0
    /// Settles the kept heights once typing pauses.
    @State private var reserveSettle: Task<Void, Never>?
    /// The highlighted result's actions, open after → or a context click.
    @State private var quickActions: AskQuickActionPanel?
    /// Quick results show while the launcher's text is all there is to send:
    /// quotes, files or chosen tools mean the text is written for the AI.
    private var showsQuickResults: Bool {
        guard launcher, quickSearch.isVisible,
              presentedQuickResults != nil, !paletteOpen, pluginDisplay == nil else { return false }
        let value = draft.wrappedValue
        return (value.references ?? []).isEmpty && (value.attachments ?? []).isEmpty
            && (value.skills ?? []).isEmpty && (value.mcpServers ?? []).isEmpty
    }

    /// Writes state only when the results change: the workspace composer and
    /// ordinary questions must not re-render on every keystroke for this.
    private func refreshQuickResults(resetActions: Bool = true) {
        guard launcher, searchVisible, quickSearch.isVisible else { return }
        if refreshPlugins() { quickSearch.cancel(); quickResults = nil; return }
        let sources = AskQuickResults.Sources(apps: model.quickAppsEnabled ? model.appIndex : nil,
                                              files: model.quickFilesEnabled ? model.fileIndex : nil,
                                              settings: model.launcherSearchSettings,
                                              entries: model.launcherSearchEntries(language: AppLocalization.shared.language),
                                              browsers: model.browserSearch, browserSettings: model.browserSearchSettings)
        if resetActions { quickActions = nil }
        quickSearch.update(text: draft.wrappedValue.text,
                           chinese: AppLocalization.shared.language == .simplifiedChinese,
                           calculator: model.quickCalculatorEnabled,
                           numberConversions: model.quickNumberConversionsEnabled, sources: sources)
    }

    private func refreshSearchIndex(resetActions: Bool = false) {
        guard launcher, searchVisible, quickSearch.isVisible else { return }
        if [AskFileSearchPlugin.id, AskBrowserSearchPlugin.tabsID, AskBrowserSearchPlugin.bookmarksID].contains(plugins.keyword?.pluginID ?? "") {
            plugins.refreshLiveResults(text: draft.wrappedValue.text, selection: draft.wrappedValue.sentSelection,
                                       language: AppLocalization.shared.language)
        } else {
            refreshQuickResults(resetActions: resetActions)
        }
    }

    private func quickResultsChanged() {
        let next = presentedQuickResults
        let reserve = AskLauncherHeightReserve.holding(quickReserve, content: next.map { AskQuickResultsView.height(for: $0) } ?? 0)
        if reserve != quickReserve { quickReserve = reserve }
        reportHeight()
        scheduleReserveSettle()
    }

    /// Once typing pauses, the space kept below shorter results goes away.
    private func scheduleReserveSettle() {
        guard launcher else { return }
        reserveSettle?.cancel()
        reserveSettle = Task { @MainActor in
            try? await Task.sleep(for: AskLauncherHeightReserve.settleDelay)
            guard !Task.isCancelled else { return }
            settleReserves()
        }
    }

    /// Publish the settled height immediately; the window controller animates
    /// the panel and its viewport together. Recording keeps its panel's height.
    private func settleReserves() {
        guard !active, !quickSearch.isSearching else { return }
        let quick = AskLauncherHeightReserve.settled(quickReserve,
                                                     content: quickResults.map(AskQuickResultsView.height(for:)) ?? 0)
        let plugin = AskLauncherHeightReserve.settled(pluginReserve,
                                                      content: pluginDisplay.map(AskPluginResultsView.height(for:)) ?? 0)
        guard quick != quickReserve || plugin != pluginReserve else { return }
        quickReserve = quick; pluginReserve = plugin
        reportHeight()
    }

    /// Copies a quick result, closing the launcher when asked to, opens an
    /// application or file, or sends the text to the AI.
    private func runQuickResult(_ row: AskQuickResults.Row, close: Bool) {
        guard quickSearch.pendingResults == nil,
              quickSearch.isCurrent(text: draft.wrappedValue.text), let results = quickResults else { return }
        quickActions = nil
        switch row {
        case let .feature(index):
            guard results.features.indices.contains(index) else { return }
            let entry = results.features[index]
            if let command = entry.command, close {
                performPluginAction(.init(kind: .systemCommand(command), title: entry.title, symbol: entry.symbol))
            } else if close, entry.keyword.pluginID == AskSettingsPlugin.id {
                performPluginAction(.init(kind: .openSettings, title: entry.title, symbol: entry.symbol))
            } else if close, entry.keyword.pluginID == AskOpenChatPlugin.id {
                model.enterLauncherSearchEntry(entry)
                performPluginAction(.init(kind: .openChat, title: entry.title, symbol: entry.symbol))
            } else {
                model.enterLauncherSearchEntry(entry)
                pluginHighlight = 0
                pluginReserve = 0
            }
            return
        case .askAI: model.submitLauncher(); return
        case .showAllFiles: showAllFiles(); return
        case .app, .pane:
            if let app = results.app(at: row) {
                model.openQuickApp(app)
                onDismiss()
            }
            return
        case .file:
            if let file = results.file(at: row) { runFileAction(.open, file) }
            return
        case let .browser(index):
            guard results.browserEntries.indices.contains(index) else { return }
            let item = results.browserEntries[index].item(settings: model.browserSearchSettings)
            if let action = item.actions.first { performPluginAction(action) }
            return
        case .calculation, .format: break
        }
        guard results.isEnabled(row), let value = results.value(of: row) else { return }
        AskQuickResults.copy(value)
        if close {
            model.finishQuickResult()
            onDismiss()
        }
    }

    /// File mode with the same text: every file that matches, with filters.
    private func showAllFiles() {
        guard let keyword = plugins.availableKeywords.first(where: { $0.enabled && $0.pluginID == AskFileSearchPlugin.id })
        else { return }
        draft.wrappedValue.text = keyword.keyword + " " + draft.wrappedValue.text
    }

    /// Carries out an action on a found file; closes the launcher unless it says otherwise.
    private func runFileAction(_ action: AskQuickAction, _ file: AskFileHit) {
        switch model.performQuickFileAction(action, file) {
        case .close: onDismiss()
        case .stay: break
        case let .panel(panel):
            quickActions = panel
        case let .text(text): draft.wrappedValue.text = text
        }
    }

    private func runAppAction(_ action: AskQuickAction, _ app: AskAppEntry) {
        if model.performQuickAppAction(action, app) == .close { onDismiss() }
    }

    /// Runs the action chosen in the panel, asking again before moving to the trash.
    private func runPanelAction(_ action: AskQuickAction) {
        guard var panel = quickActions else { return }
        if action == .trash, !panel.confirming {
            panel.highlighted = panel.actions.firstIndex(of: .trash) ?? panel.highlighted
            panel.confirming = true
            quickActions = panel
            return
        }
        switch panel.target {
        case let .app(app): quickActions = nil; runAppAction(action, app)
        case let .file(file): runFileAction(action, file)
        }
    }

    /// Opens the actions of the highlighted row; false when it has none.
    private func openQuickActions(_ results: AskQuickResults) -> Bool {
        let row = results.highlightedRow
        let target: AskQuickActionPanel.Target
        if let file = results.file(at: row) {
            target = .file(file)
        } else if let app = results.app(at: row) {
            target = .app(app)
        } else {
            return false
        }
        guard let panel = AskQuickActionPanel.make(for: target) else { return false }
        quickActions = panel
        return true
    }

    /// Selects the clicked file by path, so a search update cannot redirect its actions.
    private func showQuickFileActions(_ file: AskFileHit) {
        guard showsQuickResults, !active, !quickResultsArePending, var results = quickResults,
              let fileIndex = results.files.firstIndex(where: { $0.path == file.path }),
              let rowIndex = results.rows.firstIndex(of: .file(fileIndex)) else { return }
        results.highlight(rowIndex)
        quickResults = results
        _ = openQuickActions(results)
    }

    /// The panel has the keys while it is open: arrows choose, Return runs, ← and esc close.
    private func quickActionsKey(_ key: AskCommandKey) -> Bool {
        guard var panel = quickActions else { return false }
        switch key {
        case .up, .down:
            panel.move(key == .up ? -1 : 1)
            quickActions = panel
        case .enter:
            if let action = panel.highlightedAction { runPanelAction(action) }
        case .escape:
            quickActions = nil
        default:
            return false
        }
        return true
    }

    /// Return runs the highlighted row (copy, or open an application or file), ⌘Return
    /// asks the AI, Tab writes a calculation's result into the editor to keep
    /// calculating, the arrows move, → opens a found item's actions, and the
    /// actions' own shortcuts work on the highlighted file.
    private func quickResultsKey(_ key: AskCommandKey) -> Bool {
        guard showsQuickResults, !active, var results = quickResults else { return false }
        // Retained rows are a visual placeholder, never a shortcut target.
        if quickResultsArePending {
            switch key {
            case .commandEnter: model.submitLauncher(); return true
            case .escape, .commandO, .commandC, .commandZ, .shiftTab,
                 .commandD, .commandE, .commandS, .commandB: return false
            default: return true
            }
        }
        if quickActionsKey(key) { return true }
        let file = results.file(at: results.highlightedRow)
        let app = results.app(at: results.highlightedRow)
        if AskQuickLook.shared.isVisible, key == .escape || key == .commandY {
            AskQuickLook.shared.close()
            return true
        }
        switch key {
        case .up, .down:
            results.move(key == .up ? -1 : 1)
            quickResults = results
        case let .number(number):
            guard quickActions == nil, results.rows.indices.contains(number - 1) else { return false }
            let row = results.rows[number - 1]
            guard results.isEnabled(row) else { return true }
            self.quickResults?.highlight(number - 1)
            runQuickResult(row, close: true)
        case .enter:
            runQuickResult(results.highlightedRow, close: true)
        case .commandEnter:
            model.submitLauncher()
        case .tab:
            if case .feature = results.highlightedRow {
                runQuickResult(results.highlightedRow, close: false)
                return true
            }
            guard let value = results.value(of: .calculation), !results.stale else { return false }
            draft.wrappedValue.text = value
        case .right:
            return openQuickActions(results)
        case .commandDown:
            guard results.moreFiles || !results.files.isEmpty else { return false }
            showAllFiles()
        case .commandY:
            guard let file, file.kind != .folder else { return false }
            AskQuickLook.shared.toggle(file.url)
        case .commandR:
            if let file { runFileAction(.reveal, file) } else if let app { runAppAction(.reveal, app) } else { return false }
        case .shiftCommandC:
            if let file { runFileAction(.copyPath, file) } else if let app { runAppAction(.copyPath, app) } else { return false }
        case .optionCommandC:
            guard let file, file.kind != .folder else { return false }
            runFileAction(.copyFile, file)
        case .shiftCommandEnter:
            guard let file else { return false }
            runFileAction(.askAI, file)
        case .optionEnter:
            guard let file, file.kind != .folder else { return false }
            runFileAction(.openWith, file)
        case .commandC:
            guard case let .browser(index) = results.highlightedRow, results.browserEntries.indices.contains(index) else { return false }
            AskQuickResults.copy(results.browserEntries[index].url)
        case .escape, .shiftTab, .commandD, .commandE, .commandZ, .commandS, .commandB, .commandO:
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
            let asks = AskPluginDisplay.offersAskAI(question: draft.wrappedValue.text,
                                                    selection: draft.wrappedValue.sentSelection,
                                                    usesSelection: plugin.usesSelectionInput, output: plugins.output)
            return AskPluginDisplay(hint: nil, title: plugin.title, symbol: plugin.symbol, optionName: plugin.optionName,
                                    phase: plugins.phase, previous: plugins.previous, partial: plugins.partial,
                                    comparing: plugins.comparing, highlighted: asks ? pluginHighlight : 0,
                                    offersAskAI: asks, savesNoteWhenDone: plugins.savesNoteWhenDone)
        }
        if quickSearch.presentation?.features.isEmpty != false,
           let hint = plugins.hint, let plugin = plugins.plugin(for: hint) {
            return AskPluginDisplay(hint: hint, title: plugin.title, symbol: plugin.symbol, phase: .waiting,
                                    highlighted: pluginHighlight)
        }
        return nil
    }

    /// Keyword mode takes the launcher's text first. True when it handled it:
    /// a keyword became a chip (the editor now holds only its argument) or is active.
    private func refreshPlugins() -> Bool {
        let text = draft.wrappedValue.text
        let previousHint = plugins.hint
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
        // Local entry points default to their feature; text-processing hints default to Ask AI.
        if let hint = plugins.hint, hint != previousHint { pluginHighlight = plugins.plugin(for: hint)?.entersOnReturn == true ? 0 : 1 }
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
        if pluginDisplay?.hint?.pluginID == AskSettingsPlugin.id || plugins.keyword?.pluginID == AskSettingsPlugin.id {
            performPluginAction(.init(kind: .openSettings, title: "", symbol: ""))
            return
        }
        if pluginDisplay?.hint?.pluginID == AskOpenChatPlugin.id || plugins.keyword?.pluginID == AskOpenChatPlugin.id {
            openChat()
            return
        }
        if pluginDisplay?.hint != nil { _ = acceptPluginHint(); return }
        switch plugins.phase {
        case let .ready(plan):
            // A plan that acts (open a search) must be for the text as typed; it lands within moments.
            if let action = plan.action(for: .enter) {
                if plugins.isPlanCurrent { performPluginAction(action) }
            } else {
                plugins.run()
            }
        case let .failed(_, failure):
            if let action = failure.action(for: .enter) { performPluginAction(action) } else if failure.retry { plugins.run() }
        case let .done(_, output):
            if plugins.isPlanCurrent, let action = output.action(for: .enter) { performPluginAction(action) }
        case let .running(plan):
            // A plan that acts (`dict` opening the word book) need not wait for its preview.
            if let action = plan.action(for: .enter), plugins.isPlanCurrent { performPluginAction(action) }
        case .waiting:
            plugins.update(text: draft.wrappedValue.text, selection: draft.wrappedValue.sentSelection,
                           language: AppLocalization.shared.language, runWhenPlanned: true)
        }
    }

    private func performPluginAction(_ action: AskPluginAction) {
        if case .enterKeyword = action.kind { pluginHighlight = 0; pluginReserve = 0 }
        if case let .focusBrowserTab(target) = action.kind {
            Task {
                if await model.focusBrowserTab(target) { onDismiss() }
                else { refreshSearchIndex() }
            }
            return
        }
        if model.performPluginAction(action) == .close { onDismiss() }
    }

    private func askAIFromPlugin() {
        if let action = plugins.output?.askAIAction {
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
            case .enter: if pluginHighlight == 0 { runPluginMain(); return true } else { return false }
            default: return false
            }
            return true
        }
        switch key {
        case .up, .down: movePluginHighlight(key == .up ? -1 : 1, offersAskAI: display.offersAskAI)
        case let .number(number):
            guard let count = AskPluginResultsView.numberedItemCount(display) else { return false }
            if number == count + 1, display.offersAskAI {
                askAIFromPlugin()
            } else {
                guard number <= count else { return false }
                pluginHighlight = 0
                guard plugins.selectItem(number - 1) else { return true }
                runPluginMain()
            }
        case .tab:
            // ⇥ on a row that completes goes one level deeper; elsewhere it changes the option.
            if let completion = plugins.output?.selected?.autocomplete {
                performPluginAction(AskPluginAction(kind: .runWith(completion), title: "", symbol: "", shortcut: nil))
            } else {
                _ = plugins.cycle(1, selection: selection, text: text, language: language)
            }
        case .shiftTab: _ = plugins.cycle(-1, selection: selection, text: text, language: language)
        case .enter: if display.asksAI { askAIFromPlugin() } else { runPluginMain() }
        case .commandEnter: if display.offersAskAI { askAIFromPlugin() }
        case .optionEnter, .commandR, .commandD, .shiftCommandC, .commandS, .commandB, .commandO:
            let shortcut: AskPluginAction.Shortcut = switch key {
            case .optionEnter: .optionEnter
            case .commandR: .commandR
            case .commandD: .commandD
            case .commandS: .commandS
            case .commandB: .commandB
            case .commandO: .commandO
            default: .shiftCommandC
            }
            // A result still streaming can already be saved (⌘S) or moved to a window (⌘O).
            let offering = [.commandS, .commandO].contains(key) ? plugins.currentOutput : plugins.output
            // ⇧⌘C, ⌘S, ⌘B and ⌘O fall through to the editor when the result offers nothing for them.
            guard let action = offering?.action(for: shortcut) else {
                return ![.shiftCommandC, .commandS, .commandB, .commandO].contains(key)
            }
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
        case .commandZ: return model.undoWorkflowCopy()
        // Esc steps back through the launcher's layers in `escapeKey`.
        case .escape: return false
        case .commandY:
            // A list of files (file mode) previews the chosen one.
            guard case let .fileIcon(url)? = plugins.output?.selected?.icon else { return false }
            AskQuickLook.shared.toggle(url)
        case .shiftCommandEnter:
            // Ask the AI about the chosen file: it becomes an attachment of a new question.
            guard case let .fileIcon(url)? = plugins.output?.selected?.icon else { return false }
            model.attachFileToLauncher(url)
        case .right, .optionCommandC, .commandDown: return false
        }
        return true
    }

    /// A workflow waits for an answer in the bottom bar: ↩ allows, esc does not.
    private func approvalKey(_ key: AskCommandKey) -> Bool {
        guard launcher, !active, model.workflowApproval != nil, key == .enter || key == .escape else { return false }
        model.answerWorkflowApproval(key == .enter)
        return true
    }

    /// The arrows move through a list's rows, then on to "Ask AI" (when offered) and back around.
    private func movePluginHighlight(_ delta: Int, offersAskAI: Bool) {
        if pluginHighlight == 0, plugins.moveSelection(delta) { return }
        guard offersAskAI else {
            // Without "Ask AI" the list wraps around on itself.
            pluginHighlight = 0
            if let indices = plugins.output?.selectableIndices, let index = delta < 0 ? indices.last : indices.first {
                plugins.selectItem(index)
            }
            return
        }
        pluginHighlight = pluginHighlight == 0 ? 1 : 0
        if pluginHighlight == 0, let indices = plugins.output?.selectableIndices {
            guard let index = delta < 0 ? indices.last : indices.first else { pluginHighlight = 1; return }
            plugins.selectItem(index)
        }
    }

    /// ⌫ in an empty editor in keyword mode turns the chip back into text.
    private func removeKeyword() -> Bool {
        guard launcher, !active, plugins.isActive else { return false }
        draft.wrappedValue.text = plugins.deactivate() ?? ""
        pluginReserve = 0
        return true
    }

    private var pluginHeight: CGFloat {
        pluginDisplay.map { AskLauncherHeightReserve.holding(pluginReserve, content: AskPluginResultsView.height(for: $0)) } ?? 0
    }

    /// The launcher offers its starting points until something is typed. They
    /// stay (disabled) while dictating, so the panel never jumps mid-recording.
    private var showsLauncherSuggestions: Bool {
        launcher && !plugins.isActive && draft.wrappedValue.text.isEmpty && (draft.wrappedValue.references ?? []).isEmpty
            && (draft.wrappedValue.attachments ?? []).isEmpty && !model.isLoadingAttachments(launcher: true) && !paletteOpen
    }

    /// What the launcher's home offers for its context; empty outside the launcher.
    private var home: [AskLauncherHome.Section] { launcher ? model.launcherHome() : [] }

    private var homeHeight: CGFloat { AskLauncherSuggestions.height(for: home) }

    private var highlightedHomeItem: AskLauncherHome.Item? {
        let items = AskLauncherHome.items(home)
        return items.indices.contains(suggestionIndex) ? items[suggestionIndex] : items.first
    }

    /// Runs a home row: a keyword on the selection, a question, or a conversation.
    /// A chip enters its keyword and waits, as typing it and a space would.
    private func pick(_ item: AskLauncherHome.Item) {
        let keyword: AskKeyword, run: Bool
        switch item {
        case let .row(row):
            switch row.action {
            case let .keyword(chosen): keyword = chosen; run = true
            case let .ask(question): model.askFromLauncherHome(question); return
            case let .conversation(id): model.openConversationFromLauncher(id); return
            }
        case let .chip(chip): keyword = chip.keyword; run = false
        }
        pluginHighlight = 0
        pluginReserve = 0
        model.enterLauncherKeyword(keyword, run: run)
        reportHeight()
    }
    private var sendControl: AskSendControl {
        guard !launcher else { return .send(enabled: canSend) }
        // Stop only while the run works, waits on an approval or waits for credits: a run
        // waiting for a recovery decision is stopped from its card, so the composer offers no second Stop.
        let working = model.isBusy && model.runPhase?.offersStop != false
        return AskSendControl.resolve(busy: working, hasDraft: model.draft.canSend,
                                      canSend: canSend, editingQueued: editingQueued)
    }

    /// Problems to know about or fix, most urgent first. The workspace shows its
    /// send errors in the transcript, next to the answer they belong to.
    private var notices: [AskComposerNotice] {
        AskComposerNotice.resolve(
            sendError: launcher && model.submissionIssues[launcher] == nil ? model.error : nil,
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
        case .sendError:
            return { model.error = nil }
        case .voice:
            return { voice.error = nil }
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
            .onPreferenceChange(AskComposerSupplementalHeight.self) { height in
                if abs(supplementalHeight - height) > 0.5 {
                    supplementalHeight = height
                    if launcher { reportHeight() }
                }
            }
            .onPreferenceChange(AskComposerHeight.self) { height in
                if !launcher, abs(cardHeight - height) > 0.5 { cardHeight = height }
            }
            .onChange(of: editorHeight) { _ in reportHeight() }
            .onChange(of: showsLauncherSuggestions) { _ in reportHeight() }
            // The home fills in as the context arrives after the panel shows.
            .onChange(of: homeHeight) { _ in reportHeight() }
            .onChange(of: draft.wrappedValue.text) { _ in
                refreshQuickResults()
                if draft.wrappedValue.text.isEmpty {
                    reserveSettle?.cancel()
                    quickReserve = 0
                    pluginReserve = 0
                    reportHeight()
                } else if quickReserve > 0 || pluginReserve > 0 {
                    scheduleReserveSettle()
                }
            }
            .onChange(of: quickResults) { _ in quickResultsChanged() }
            .onChange(of: quickSearch.pendingResults) { _ in quickResultsChanged() }
            .onChange(of: quickSearch.isSearching) { searching in
                if !searching { scheduleReserveSettle() }
            }
            .onChange(of: pluginDisplay) { display in
                guard launcher else { return }
                if let followUp = display?.followUp {
                    // A workflow's actions run once per run; they close the launcher when they say so.
                    model.performWorkflowFollowUp(followUp, dismiss: onDismiss)
                    if followUp.closes { return }
                } else if display?.output?.dismisses == true {
                    // A workflow that only does something closes the launcher when it is done.
                    model.finishPluginResult(); onDismiss(); return
                }
                let reserve = display.map {
                    AskLauncherHeightReserve.holding(pluginReserve, content: AskPluginResultsView.height(for: $0))
                } ?? 0
                if reserve != pluginReserve { pluginReserve = reserve }
                reportHeight()
                scheduleReserveSettle()
            }
            .onChange(of: draft.wrappedValue.sentSelection) { _ in if launcher, plugins.isActive { refreshQuickResults() } }
            .onChange(of: noticeRows) { _ in reportHeight() }
            .onChange(of: submissionIssue) { _ in reportHeight() }
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
            .onAppear { searchVisible = true; refreshQuickResults(); reportHeight() }
            .onDisappear {
                reserveSettle?.cancel()
                if launcher { searchVisible = false; quickSearch.cancel() }
            }
            .onChange(of: quickSearch.isVisible) { visible in if visible { refreshQuickResults() } }
            .onReceive(NotificationCenter.default.publisher(for: AskAppIndex.didChange)) { notification in
                if (notification.object as AnyObject?) === model.appIndex { refreshQuickResults(resetActions: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: AskFileIndex.didChange)
                .debounce(for: .milliseconds(80), scheduler: RunLoop.main)) { notification in
                if (notification.object as AnyObject?) === model.fileIndex { refreshSearchIndex() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .askLauncherSearchSettingsDidChange)) { notification in
                if let store = notification.object as? SettingsStore, store.defaults === model.modelLibrary.settings.defaults {
                    refreshSearchIndex(resetActions: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsDidChange)) { _ in
                voiceShortcut = model.modelLibrary.settings.activationHotkey
            }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if launcher {
                supplementalContent
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: AskComposerSupplementalHeight.self, value: geometry.size.height)
                    })
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
            if launcher {
                ZStack(alignment: .top) {
                    // EmptyView does not participate in layout. Keep a real
                    // viewport while the last results disappear during shrinkage.
                    Color.clear
                    launcherResults
                }
                .frame(height: launcherResultsViewportHeight, alignment: .top)
                .clipped()
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
        .modifier(AskWorkspaceCardDepth(enabled: !launcher && interfaceStyle.usesGlass, corner: chrome.corner))
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
        .transaction { transaction in
            if launcher {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    /// Follow the actual panel height so the footer never jumps to a target
    /// height before the window reaches it.
    private var launcherResultsViewportHeight: CGFloat {
        let natural = active ? voicePanelHeight : resultsHeight
        guard let availableHeight else { return natural }
        let chromeHeight = desiredLauncherHeight - natural - AskMetrics.launcherGutter * 2
        return max(0, availableHeight - chromeHeight)
    }

    private var launcherResults: some View {
        Group {
            if active {
                // Recording takes the results' place at their height, so the panel stays put.
                AskVoicePanel(live: voice.live, listening: listening, height: voicePanelHeight, token: contextToken)
            } else if showsLauncherSuggestions {
                AskLauncherSuggestions(sections: home, highlighted: $suggestionIndex, onPick: pick)
                    .disabled(active)
            } else if let pluginDisplay {
                AskPluginResultsView(display: pluginDisplay, question: draft.wrappedValue.text,
                                     minimumHeight: pluginHeight,
                                     onMain: runPluginMain, onAction: performPluginAction,
                                     onAskAI: askAIFromPlugin,
                                     onHighlight: { pluginHighlight = $0 },
                                     onSelectItem: { id in
                                         guard plugins.isPlanCurrent, let output = plugins.output,
                                               let index = output.items.firstIndex(where: { $0.id == id }) else { return false }
                                         return plugins.selectItem(index)
                                     })
            } else if showsQuickResults, let quickResults = presentedQuickResults {
                AskQuickResultsView(results: quickResults, question: draft.wrappedValue.text,
                                    minimumHeight: resultsHeight, viewportHeight: launcherResultsViewportHeight,
                                    actions: quickActions,
                                    thumbnails: model.launcherSearchSettings.fileIcons == .thumbnails,
                                    onRun: { row, close in
                                        // A previous render may carry an old array index.
                                        // Resolve its identity against the current batch before running.
                                        guard let current = self.quickResults,
                                              let target = current.rows.first(where: {
                                                  current.identity(of: $0) == quickResults.identity(of: row)
                                              }) else { return }
                                        runQuickResult(target, close: close)
                                    },
                                    onHighlight: { index in
                                        guard !quickResultsArePending, quickResults.rows.indices.contains(index),
                                              let current = self.quickResults,
                                              let target = current.rows.firstIndex(where: {
                                                  current.identity(of: $0) == quickResults.identity(of: quickResults.rows[index])
                                              }) else { return }
                                        self.quickResults?.highlight(target)
                                    },
                                    onAction: runPanelAction, onShowFileActions: showQuickFileActions)
                    // Pending rows keep their brightness instead of flashing disabled
                    // on every keystroke. All keyboard and action paths also reject them.
                    .disabled(active)
                    .allowsHitTesting(!quickResultsArePending)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var submissionIssue: AskSubmissionIssue? { model.submissionIssues[launcher] }

    private var showsScreenshotPermissionHint: Bool {
        !draft.wrappedValue.includeScreenshot && !model.screenCaptureAllowed
            && model.screenshotCapability(launcher: launcher).canAttach
    }

    private var hasSupplementalContent: Bool {
        showsScreenshotPermissionHint || submissionIssue != nil || !notices.isEmpty || (!launcher && !model.queuedMessages.isEmpty) || editingQueued
            || !(draft.wrappedValue.references ?? []).isEmpty || showsStrip
    }

    private var supplementalContent: some View {
        VStack(spacing: 0) {
            if showsScreenshotPermissionHint {
                Button { screenshotAction?() } label: {
                    Label(L("ask.capture.optIn"), systemImage: "camera.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(model.capturing)
                .padding(.horizontal, chrome.horizontalInset)
                .padding(.top, 8)
                .accessibilityIdentifier("ask.screenshot.optIn")
            }
            if let issue = submissionIssue {
                AskSubmissionIssueView(issue: issue, onModels: { model.onOpenSettings?(.models) },
                                       onSignIn: model.onSignIn)
                    .padding(.top, AskMetrics.bannerSpacing)
                    .padding(.horizontal, AskMetrics.composerNoticeInset)
            }
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

    private func openChat() {
        Task { await model.openChatFromLauncher() }
    }

    /// Esc steps back one layer (`AskLauncherEscape`); false closes the launcher.
    private func escapeKey() -> Bool {
        let step = AskLauncherEscape.resolve(.init(
            quickLook: AskQuickLook.shared.isVisible, menu: AskGlassMenuPresenter.shared.isShowing || contextPanelOpen,
            actions: quickActions != nil, approval: model.workflowApproval != nil,
            running: plugins.isRunning, keyword: plugins.isActive
        ))
        switch step {
        case .closeQuickLook: AskQuickLook.shared.close()
        case .closeMenu:
            contextPanelOpen = false
            AskGlassMenuPresenter.shared.hide()
        case .closeActions: quickActions = nil
        case .declineApproval: model.answerWorkflowApproval(false)
        case .cancelRun: _ = plugins.cancelRun()
        case .exitKeyword: exitKeyword()
        case .closeLauncher: return false
        }
        return true
    }

    /// Leaves keyword mode, keeping the text typed after the keyword as plain launcher text.
    private func exitKeyword() {
        plugins.deactivate()
        pluginHighlight = 0
        pluginReserve = 0
        refreshQuickResults()
        reportHeight()
    }

    private func commandKey(_ key: AskCommandKey) -> Bool {
        if launcher, !active, key == .escape { return escapeKey() }
        if (key == .enter || key == .commandEnter),
           AskPermissionMode.command(draft.wrappedValue.text).recognized,
           AskPermissionMode.command(draft.wrappedValue.text).mode != nil || !paletteOpen {
            _ = model.consumeModeCommand(launcher: launcher)
            closePalette()
            return true
        }
        // Return can arrive before SwiftUI has refreshed the keyword hint.
        if launcher, key == .enter, !plugins.isActive, !showsQuickResults,
           plugins.hint?.pluginID != AskSettingsPlugin.id || pluginHighlight == 0 {
            let match = AskKeywordMatcher.match(draft.wrappedValue.text, keywords: plugins.availableKeywords)
            switch match {
            case let .hint(keyword) where keyword.pluginID == AskSettingsPlugin.id,
                 let .active(keyword, _) where keyword.pluginID == AskSettingsPlugin.id:
                performPluginAction(.init(kind: .openSettings, title: "", symbol: ""))
                return true
            default: break
            }
        }
        if launcher, key == .enter, !plugins.isActive, !showsQuickResults,
           plugins.hint?.pluginID != AskHistoryPlugin.id || pluginHighlight == 0,
           model.enterLauncherKeywordFromText(pluginID: AskHistoryPlugin.id) {
            pluginHighlight = 0
            pluginReserve = 0
            return true
        }
        if launcher, key == .enter, !plugins.isActive, !showsQuickResults,
           plugins.hint?.pluginID != AskPrefixPlugin.id || pluginHighlight == 0,
           model.enterKeywordDirectoryFromLauncher() {
            pluginHighlight = 0
            pluginReserve = 0
            return true
        }
        if launcher, key == .enter, !plugins.isActive, !showsQuickResults,
           plugins.hint?.pluginID != AskOpenChatPlugin.id || pluginHighlight == 0 {
            let match = AskKeywordMatcher.match(draft.wrappedValue.text, keywords: model.launcherKeywords)
            switch match {
            case let .hint(keyword) where keyword.pluginID == AskOpenChatPlugin.id,
                 let .active(keyword, _) where keyword.pluginID == AskOpenChatPlugin.id:
                openChat()
                return true
            default: break
            }
        }
        guard paletteOpen else { return approvalKey(key) || pluginKey(key) || quickResultsKey(key) }
        switch key {
        case .up: palette.move(-1)
        case .down: palette.move(1)
        case .enter: pickCommand(palette.highlighted)
        case .tab: complete()
        case .escape:
            dismissedSlash = slash?.range.location
            closePalette()
        case .commandEnter, .optionEnter, .shiftTab, .commandR, .commandD, .commandC, .shiftCommandC, .commandE,
             .commandZ, .commandS, .commandB, .commandO, .right, .commandY, .optionCommandC, .shiftCommandEnter, .commandDown,
             .number:
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
        AskComposerTextView(
            text: draft.text,
            placeholder: placeholder,
            placeholderSingleLine: launcher,
            voice: voice,
            contextID: contextID,
            fontSize: chrome.editorFontSize,
            maximumHeight: layout.editorMaximumHeight,
            onSubmit: submit,
            onDismiss: { if editingQueued { model.cancelQueuedEdit() } else { onDismiss() } },
            onHeightChange: { editorHeight = $0 },
            onAttach: { model.addAttachments($0, launcher: launcher) },
            onDropTargetChange: { editorDropTargeted = $0 },
            onSlashQuery: launcher ? nil : slashChanged,
            onCommandKey: commandKey,
            onEmptyBackspace: launcher ? { removeKeyword() || removeLastContext() } : nil,
            onOpenChat: launcher ? openChat : nil,
            onContextShortcut: launcher ? toggleContextPanel : nil
        )
        .frame(height: min(editorHeight, layout.editorMaximumHeight))
        .disabled(model.isOpeningChat || (!launcher && model.isLoadingSelection))
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

    /// The launcher's first row: the recording dot while dictating,
    /// the editor (the words being recognised), then the microphone
    /// and open-chat buttons, or the elapsed time, cancel and stop while recording.
    private var launcherHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            if active {
                AskVoiceOrb(live: voice.live, listening: listening)
                    .padding(.vertical, 2)
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
                .accessibilityLabel(AskVoiceButton.title(phase: voice.phase, contextMatches: voice.context == contextID))
                .accessibilityIdentifier("ask.composer.voice")
            if !active {
                AskLauncherOpenChatButton(enabled: model.canOpenChatFromLauncher, action: openChat)
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
            permissionModeMenu
            Rectangle().fill(AskTheme.launcherSeparator).frame(width: 1, height: 18).padding(.horizontal, 4)
            contextChips
                .disabled(active)
                .opacity(Self.recordingDim(active))
                // Command-K keeps the context panel reachable without adding a footer control.
                // It is a glass menu like the composer's others: the same material, and Esc closes only it.
                .askMenu(isPresented: $contextPanelOpen, glass: true) {
                    AskObservedContent(model: model) { contextPanel }
                }
            // In the launcher the empty space moves the panel; it lays out exactly like the spacer.
            Spacer(minLength: 8)
                .frame(maxHeight: .infinity)
                .background { if let windowDrag { AskWindowDragArea(handlers: windowDrag) } }
            Group {
                if let approval = model.workflowApproval, !active {
                    AskWorkflowApprovalView(approval: approval) { model.answerWorkflowApproval($0) }
                        .layoutPriority(1)
                } else if let actions = model.currentWorkflowActions, !active {
                    AskWorkflowActionsSummaryView(state: actions)
                        .layoutPriority(1)
                } else if let feedback = model.capturedContentFeedback(launcher: true), !active {
                    AskCapturedContentFeedbackView(feedback: feedback) {
                        model.undoCapturedContent(launcher: true)
                    }
                    .layoutPriority(1)
                } else if let feedback = model.commandFeedback, !active {
                    AskComposerFootnote(text: feedback)
                        .transition(.opacity)
                        .layoutPriority(1)
                } else {
                    // The longest version that fits after the model; nothing when even the main key does not.
                    ViewThatFits(in: .horizontal) {
                        ForEach(AskLauncherContext.hintTiers(launcherHint), id: \.self) { hint in
                            Text(hint)
                                .font(.system(size: 11))
                                .foregroundStyle(AskTheme.launcherMetaText)
                                .lineLimit(1)
                        }
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .accessibilityHidden(true)
                    // Passive hints share the empty bar's drag behavior.
                    .overlay { if let windowDrag { AskWindowDragArea(handlers: windowDrag) } }
                    // Shorten the passive hints before shrinking the model control.
                    .layoutPriority(0.5)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.commandFeedback)
        .padding(.leading, chrome.footerLeadingInset)
        .padding(.trailing, 14)
        .frame(height: layout.footerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
        }
    }

    private var launcherHint: String {
        if !active, let pluginDisplay { return AskPluginResultsView.hint(for: pluginDisplay) }
        if !active, showsLauncherSuggestions, let item = highlightedHomeItem {
            return AskLauncherSuggestions.hint(for: item, hasContext: contextToken != nil)
        }
        return AskLauncherContext.hint(voice: active ? voice.phase : .idle,
                                quickResults: showsQuickResults && !showsLauncherSuggestions ? presentedQuickResults : nil,
                                hasContext: contextToken != nil)
    }

    /// The launcher's results area: its starting points or quick results.
    private var resultsHeight: CGFloat {
        if showsLauncherSuggestions { return homeHeight }
        if pluginDisplay != nil { return pluginHeight }
        if showsQuickResults, let quickResults = presentedQuickResults {
            return AskLauncherHeightReserve.holding(quickReserve, content: AskQuickResultsView.height(for: quickResults))
        }
        // Keep the viewport until typing settles, including a final empty batch.
        return quickReserve
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
            permissionModeMenu
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
                .accessibilityLabel(AskVoiceButton.title(phase: voice.phase, contextMatches: voice.context == contextID))
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

    private var permissionModeMenu: some View {
        AskPermissionModeMenu(mode: model.permissionMode(launcher: launcher),
                              compact: launcher || layout.width < 800, bare: launcher) { mode in
            model.setPermissionMode(mode, launcher: launcher)
        }
        .disabled(active || (!launcher && model.isLoadingSelection))
    }

    /// Attach, where the conversation is kept, and the model: the same in both composers.
    @ViewBuilder private var composerTools: some View {
        AskAttachButton(model: model, launcher: launcher,
                        disabled: active || (!launcher && model.isLoadingSelection))
            .opacity(Self.recordingDim(active))
        AskStorageButton(model: model, launcher: launcher)
            .disabled(active)
            .opacity(Self.recordingDim(active))
        AskModelMenu(library: model.modelLibrary, reference: Binding(
            get: { model.modelReference(launcher: launcher) },
            set: { model.selectModel($0, launcher: launcher) }
        ), disabled: active || (!launcher && (model.isBusy || model.isLoadingSelection)),
           hasImage: !launcher && model.hasConversationImages, compact: true,
           condensed: layout.condensedFooter,
           showsChevron: false,
           cloudAvailable: model.cloudAvailable(launcher: launcher),
           onManage: model.onOpenSettings.map { open in { open(.models) } },
           effort: $model.reasoningEffort)
        .opacity(Self.recordingDim(active))
        // In the launcher the model outranks the key hints, which shorten instead.
        .layoutPriority(launcher ? 1 : 0)
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

    /// The footer holds switches; the launcher previews its screenshot on hover.
    private var contextChips: some View {
        HStack(spacing: AskContextChips.spacing) {
            ForEach(contextItems.filter { $0.kind == .screenshot || $0.kind == .memory }) { item in
                if item.kind == .screenshot {
                    AskIconChip(item: screenshotSwitch(item), action: screenshotToggleAction,
                                screenshot: screenshotHoverPreview)
                        .accessibilityIdentifier("ask.context.screenshot.toggle")
                } else {
                    AskIconChip(item: item, action: memoryToggle)
                }
            }
        }
        .fixedSize()
    }

    private var screenshotHoverPreview: NSImage? {
        guard launcher, !active, !model.capturingScreenshot else { return nil }
        switch screenshotState {
        case .attached, .off: return screenshotThumbnail
        case .failed, .unavailable: return nil
        }
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

    private var desiredLauncherHeight: CGFloat {
        // Confirmations ride in the footer, so only notice rows add height.
        let banners = noticeRows + (submissionIssue.map { $0.offersModels || $0.offersSignIn ? 3 : 1 } ?? 0)
        let commands = launcher && paletteOpen ? AskCommandPaletteView.height(for: palette) + 10 : 0
        // Recording shows its panel in the results' place, at least as tall as they were.
        let recording = launcher && active
        let quick = !recording && !showsLauncherSuggestions && pluginDisplay == nil ? resultsHeight : 0
        let panel = recording ? voicePanelHeight : 0
        let keyword = !recording ? pluginHeight : 0
        if launcher {
            return AskMetrics.launcherHeight(editor: editorHeight, banners: 0)
                + supplementalHeight + commands + quick + panel + keyword
                + (!recording && showsLauncherSuggestions ? homeHeight : 0)
        }
        return AskMetrics.launcherHeight(editor: editorHeight, banners: banners,
                                                 suggestions: !recording && showsLauncherSuggestions ? homeHeight : 0,
                                                 attachments: showsStrip,
                                                 attachmentHeight: attachmentHeight) + commands + quick + panel + keyword
    }

    private func reportHeight() {
        onHeightChange(desiredLauncherHeight)
    }
}

/// Redraws content shown outside the composer (a glass menu) as the model changes.
private struct AskObservedContent<Content: View>: View {
    @ObservedObject var model: AskConversationModel
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
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
