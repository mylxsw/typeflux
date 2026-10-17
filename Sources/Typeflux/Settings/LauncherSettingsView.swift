import Carbon.HIToolbox
import SwiftUI

/// Launcher settings panes: general preferences, results, keywords, translation, the
/// clipboard and workflows. These run from the launcher without the Agent, so they live on their own page.
@MainActor
struct LauncherSettingsView: View {
    let settings: SettingsStore
    var pane: LauncherSettingsPane = .basics
    var workflows: AskWorkflowStore = .shared
    /// The clipboard history whose space the clipboard pane shows; `nil` hides that section.
    var clipboardHistory: ClipboardHistoryStore?
    /// Opens the shortcut settings from the clipboard pane.
    var onEditShortcut: () -> Void = {}
    var inputSources: any AskLauncherInputSourceListing = SystemAskLauncherInputSourceSelector()

    @State var inputSourceID = ""
    @State var availableInputSources: [AskLauncherInputSource] = []
    @State var quickCalculatorEnabled = true
    @State var quickNumberConversionsEnabled = true
    @State var inputHistoryEnabled = true
    @State var inputHistoryLimit = 100
    @State var launcherPosition: AskLauncherPosition = .center
    @State private var confirmingClearInputHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            switch pane {
            case .basics:
                basicsPane
            case .search:
                LauncherSearchSettingsView(settings: settings)
            case .keywords:
                TFPaneHeader(systemImage: pane.symbol, title: pane.title)
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows)
            case .translation:
                TFPaneHeader(systemImage: pane.symbol, title: pane.title)
                AskTranslationSettingsView(settings: settings)
            case .clipboard:
                TFPaneHeader(systemImage: pane.symbol, title: pane.title)
                ClipboardSettingsView(settings: settings, history: clipboardHistory, onEditShortcut: onEditShortcut)
            case .workflows:
                AskWorkflowSettingsView(store: workflows, settings: settings)
            }
        }
        .onAppear(perform: reload)
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        )) { _ in reloadInputSources() }
        .alert(L("ask.inputHistory.clear"), isPresented: $confirmingClearInputHistory) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("ask.inputHistory.deleteAll"), role: .destructive) { settings.clearLauncherInputHistory() }
        } message: { Text(L("ask.inputHistory.clear.detail")) }
    }

    @ViewBuilder private var basicsPane: some View {
        TFPaneHeader(systemImage: pane.symbol, title: pane.title)
        TFFormSection {
            launcherPositionRow
            TFDivider.formWithIcon
            TFFormRow(title: L("launcher.inputSource.title"), detail: L("launcher.inputSource.detail"), icon: "keyboard") {
                TFPopUpButton(title: L("launcher.inputSource.title"),
                              options: inputSourceOptions.map { TFOption($0.value, $0.label) },
                              selection: Binding(get: { inputSourceID }, set: setInputSource),
                              width: TFMetrics.formControlWidth, identifier: "launcher.settings.inputSource")
            }
        }
        TFFormSection {
            TFFormRow(title: L("ask.settings.quick.calculator.title"), icon: "plus.forwardslash.minus") {
                TFSwitch(title: L("ask.settings.quick.calculator.title"),
                         isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator))
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ask.settings.quick.numberConversions.title"), icon: "number") {
                TFSwitch(title: L("ask.settings.quick.numberConversions.title"),
                         isOn: Binding(get: { quickNumberConversionsEnabled }, set: setQuickNumberConversions))
                    .accessibilityIdentifier("launcher.settings.numberConversions")
            }
        }
        TFFormSection(footnote: L("ask.inputHistory.privacy")) {
            TFFormRow(title: L("ask.inputHistory.remember"), icon: "clock.arrow.circlepath") {
                TFSwitch(title: L("ask.inputHistory.remember"),
                         isOn: Binding(get: { inputHistoryEnabled }, set: setInputHistoryEnabled))
                    .accessibilityIdentifier("launcher.settings.inputHistory")
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ask.inputHistory.limit"), icon: "list.number") {
                TFPopUpButton(title: L("ask.inputHistory.limit"),
                              options: [50, 100, 200].map { TFOption($0, String($0)) },
                              selection: Binding(get: { inputHistoryLimit }, set: setInputHistoryLimit))
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ask.inputHistory.clear"), icon: "trash") {
                TFButton(title: L("common.clear"), destructive: true) { confirmingClearInputHistory = true }
            }
        }
    }

    /// Where ⌥Space opens the launcher: always centred, or where it was last dragged.
    private var launcherPositionRow: some View {
        TFFormRow(
            title: L("settings.shortcuts.launcherPosition.title"),
            detail: L(launcherPosition == .center
                ? "settings.shortcuts.launcherPosition.center.subtitle"
                : "settings.shortcuts.launcherPosition.last.subtitle"),
            icon: "macwindow"
        ) {
            TFSegmentedControl(
                options: [TFOption(AskLauncherPosition.center, L("settings.shortcuts.launcherPosition.center")),
                          TFOption(.lastPosition, L("settings.shortcuts.launcherPosition.last"))],
                selection: Binding(get: { launcherPosition }, set: { position in setLauncherPosition(position) })
            )
            .accessibilityIdentifier("launcher.settings.position")
        }
    }

    func reload() {
        reloadInputSources()
        reloadLauncherPosition()
        quickCalculatorEnabled = settings.askQuickCalculatorEnabled
        quickNumberConversionsEnabled = settings.askQuickNumberConversionsEnabled
        inputHistoryEnabled = settings.askLauncherInputHistoryEnabled
        inputHistoryLimit = settings.askLauncherInputHistoryLimit
    }

    func reloadInputSources() {
        inputSourceID = settings.askLauncherInputSourceID
        availableInputSources = inputSources.availableSources()
    }

    var inputSourceOptions: [(label: String, value: String)] {
        var options = [(label: L("launcher.inputSource.none"), value: "")]
        options += availableInputSources.map { (label: $0.name, value: $0.id) }
        if !inputSourceID.isEmpty, !availableInputSources.contains(where: { $0.id == inputSourceID }) {
            options.append((label: L("launcher.inputSource.unavailable"), value: inputSourceID))
        }
        return options
    }

    /// Loads the stored choice without animating the segment thumb from its default on open.
    func reloadLauncherPosition() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { launcherPosition = settings.askLauncherPosition }
    }

    /// Choosing "Always center" also forgets every remembered position.
    func setLauncherPosition(_ position: AskLauncherPosition) {
        settings.askLauncherPosition = position
        reloadLauncherPosition()
    }

    func setInputSource(_ sourceID: String) {
        inputSourceID = sourceID
        settings.askLauncherInputSourceID = sourceID
    }

    func setInputHistoryEnabled(_ enabled: Bool) {
        inputHistoryEnabled = enabled
        settings.askLauncherInputHistoryEnabled = enabled
    }

    func setInputHistoryLimit(_ limit: Int) {
        inputHistoryLimit = limit
        settings.askLauncherInputHistoryLimit = limit
    }

    func setQuickCalculator(_ enabled: Bool) {
        quickCalculatorEnabled = enabled
        settings.askQuickCalculatorEnabled = enabled
    }

    func setQuickNumberConversions(_ enabled: Bool) {
        quickNumberConversionsEnabled = enabled
        settings.askQuickNumberConversionsEnabled = enabled
    }
}
