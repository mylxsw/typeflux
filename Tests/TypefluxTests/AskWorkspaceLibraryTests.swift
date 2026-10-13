import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceLibraryTests {
    @Test(arguments: InterfaceStyle.allCases)
    func workspaceMetricsUseTheLibrarySpecification(style: InterfaceStyle) {
        let metrics = style.ask
        #expect(metrics.sidebarRowHeight == TypefluxControlHeight.sidebarRow.value(for: style))
        #expect(metrics.sidebarRowCorner == TypefluxRadius.sidebarRow.value(for: style))
        #expect(metrics.searchFieldHeight == TypefluxControlHeight.textField.value(for: style))
        #expect(metrics.searchFieldCorner == TypefluxRadius.textField.value(for: style))
        #expect(metrics.filterCorner == TypefluxRadius.segmented.value(for: style))
        #expect(metrics.suggestionCorner == TypefluxRadius.form.value(for: style))
        #expect(metrics.composerCorner == TypefluxRadius.form.value(for: style))
        #expect(metrics.paletteCorner == TypefluxRadius.spotlightResults.value(for: style))
        #expect(metrics.menuCorner == TypefluxRadius.menu.value(for: style))
        #expect(metrics.menuRowCorner == TypefluxRadius.menuHighlight.value(for: style))
        #expect(metrics.hoverCardCorner == TypefluxRadius.popover.value(for: style))
        #expect(metrics.headerChipHeight == TypefluxControlHeight.toolbarItem.value(for: style))
    }

    @Test(arguments: InterfaceStyle.allCases)
    func composerRemainsSolidAndUsesSemanticBodyText(style: InterfaceStyle) {
        let chrome = AskComposerChrome.of(launcher: false, style: style)
        #expect(!chrome.glass)
        #expect(chrome.fill == TypefluxColor.controlBackground.color)
        #expect(chrome.idleBorder == TypefluxColor.separator.color)
        #expect(chrome.editorFontSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(AskMetrics.transcriptMaxWidth == 680)
        #expect(AskMetrics.composerMaxWidth - chrome.horizontalInset * 2 == AskMetrics.transcriptMaxWidth)
    }

    @Test func sharedCompatibilityNamesResolveToTheSameSemanticTokens() {
        #expect(AskTheme.accent == StudioTheme.accent)
        #expect(AskTheme.accentText == StudioTheme.accentText)
        #expect(AskTheme.accentSoft == StudioTheme.accentSoft)
        #expect(AskTheme.surface == StudioTheme.surface)
        #expect(AskTheme.controlSurface == StudioTheme.controlSurface)
        #expect(AskTheme.border == StudioTheme.border)
    }

    @Test func toolbarActionsKeepKeyboardAndAccessibilityMetadata() {
        var calls = 0
        let action = TypefluxToolbarAction(id: "ask.new", title: "New conversation", systemImage: "square.and.pencil",
                                          accessibilityIdentifier: "ask.workspace.new", shortcut: "n",
                                          modifiers: [.command, .shift], perform: { calls += 1 })
        action.perform()
        #expect(calls == 1)
        #expect(action.accessibilityIdentifier == "ask.workspace.new")
        #expect(action.shortcut == "n")
        #expect(action.modifiers == [.command, .shift])
        #expect(action.keyboardShortcut != nil)
        let defaults = TypefluxToolbarAction(id: "default", title: "Default", systemImage: "plus", perform: {})
        #expect(defaults.accessibilityIdentifier == "typeflux.toolbar.default")
        #expect(defaults.shortcut == nil)
        #expect(defaults.keyboardShortcut == nil)
        #expect(defaults.modifiers == .command)
    }

    @Test func nativeReasoningCardHandlesSupportedAndUnsupportedModels() throws {
        let suite = "native-reasoning-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([.init(id: "reasoner", name: "Reasoner", reference: "cloud:reasoner",
                                     scenarios: ["ask"], reasoning: true, reasoningEfforts: ["low", "high"])],
                              providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        for reference in ["cloud:reasoner", "missing:model"] {
            for page in [AskModelEffortCard.Page.effort, .models] {
                let view = AskModelEffortCard(library: library, reference: .constant(reference),
                                             effort: .constant(.providerDefault), loggedIn: true,
                                             page: page, nativeControls: true)
                let hosting = NSHostingView(rootView: view)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width == (page == .models
                    ? AskModelEffortCard.modelsWidth : AskModelEffortCard.width))
                #expect(hosting.fittingSize.height > 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func nativeTokensKeepPreviewAndRemovalIndependent(hasPreview: Bool) async throws {
        var previews = 0
        var removals = 0
        let remove = { removals += 1 }
        let preview: (() -> Void)? = hasPreview ? { previews += 1 } : nil
        let token = TypefluxToken("Screenshot", removeLabel: "Remove screenshot", systemImage: "photo",
                                  action: preview, onRemove: remove)
        try await TypefluxNavigationTestSupport.withWindow(token.padding(24)) { _, host in
            if hasPreview {
                _ = try SettingsBehaviorTestSupport.button("Screenshot", in: host)
                preview?()
                #expect(previews == 1)
                #expect(removals == 0)
            } else {
                #expect(!SettingsBehaviorTestSupport.elements(in: host).contains {
                    $0.label == "Screenshot" && $0.role == NSAccessibility.Role.button.rawValue
                })
            }
            _ = try SettingsBehaviorTestSupport.button("Remove screenshot", in: host)
            remove()
            #expect(removals == 1)
            #expect(previews == (hasPreview ? 1 : 0))
        }
    }

    @Test func nativeUsageSegmentsPreserveTheOptionalAllRunsSelection() async throws {
        var runID: String?
        let selection = Binding(get: { runID }, set: { runID = $0 })
        let picker = TypefluxSegmentedControl("Usage scope", selection: selection) {
            Text("All runs").tag(String?.none)
            Text("Current run").tag(Optional("run"))
        }
        try await TypefluxNavigationTestSupport.withWindow(picker.padding(24)) { _, host in
            try SettingsBehaviorTestSupport.button("Current run", in: host).press()
            #expect(runID == "run")
            try SettingsBehaviorTestSupport.button("All runs", in: host).press()
            #expect(runID == nil)
        }
    }
}
