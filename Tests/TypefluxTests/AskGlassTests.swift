import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher glass", .exclusiveUIState)
struct AskGlassTests {
    @Test func liquidGlassOnlyWhereTheSystemHasIt() {
        #expect(AskGlassMaterial.resolve(reduceTransparency: false, supportsLiquidGlass: true) == .liquidGlass)
        #expect(AskGlassMaterial.resolve(reduceTransparency: false, supportsLiquidGlass: false) == .visualEffect)
    }

    @Test func reduceTransparencyAlwaysWinsWithTheOpaqueSurface() {
        #expect(AskGlassMaterial.resolve(reduceTransparency: true, supportsLiquidGlass: true) == .opaque)
        #expect(AskGlassMaterial.resolve(reduceTransparency: true, supportsLiquidGlass: false) == .opaque)
    }

    @Test func defaultResolutionFollowsTheRunningSystem() {
        let expected: AskGlassMaterial = AskGlassMaterial.systemSupportsLiquidGlass ? .liquidGlass : .visualEffect
        #expect(AskGlassMaterial.resolve(reduceTransparency: false) == expected)
        if #unavailable(macOS 26.0) {
            #expect(!AskGlassMaterial.systemSupportsLiquidGlass)
        }
    }

    @Test func onlyTheOpaqueFallbackNeedsTheCardBorder() {
        #expect(AskGlassMaterial.liquidGlass.drawsOwnEdge)
        #expect(AskGlassMaterial.visualEffect.drawsOwnEdge)
        #expect(!AskGlassMaterial.opaque.drawsOwnEdge)
    }

    @Test func glassSoftensTheIdleBorderUnlessContrastIsIncreased() {
        let border = AskTheme.floatingBorder
        #expect(AskGlassMaterial.liquidGlass.idleBorder(border, increasedContrast: false) == AskTheme.floatingGlassEdge)
        #expect(AskGlassMaterial.visualEffect.idleBorder(border, increasedContrast: false) == AskTheme.floatingGlassEdge)
        #expect(AskGlassMaterial.liquidGlass.idleBorder(border, increasedContrast: true) == border)
        #expect(AskGlassMaterial.opaque.idleBorder(border, increasedContrast: false) == border)
    }

    @Test func chipsLightTheirIconInsteadOfACircle() {
        #expect(AskIconChipFace.iconColor(.active, hovering: false) == AskTheme.accent)
        #expect(AskIconChipFace.iconColor(.active, hovering: true) == AskTheme.accent)
        #expect(AskIconChipFace.iconColor(.neutral, hovering: false) == StudioTheme.textSecondary)
        #expect(AskIconChipFace.iconColor(.neutral, hovering: true) == StudioTheme.textPrimary)
        #expect(AskIconChipFace.iconColor(.unavailable, hovering: true) == StudioTheme.textTertiary)
        #expect(AskIconChipFace.iconColor(.warning, hovering: false) == StudioTheme.warning)
    }

    @Test func microphoneAndStorageLightTheirIconInsteadOfACircle() {
        #expect(AskVoiceButton.Appearance.iconColor(phase: .idle, hovered: false) == StudioTheme.textSecondary)
        #expect(AskVoiceButton.Appearance.iconColor(phase: .idle, hovered: true) == StudioTheme.textPrimary)
        #expect(AskVoiceButton.Appearance.iconColor(phase: .listening, hovered: false) == AskTheme.accent)
        #expect(AskStorageButton.iconColor(local: true, active: false) == AskTheme.privateTint)
        #expect(AskStorageButton.iconColor(local: false, active: false) == StudioTheme.textSecondary)
        #expect(AskStorageButton.iconColor(local: false, active: true) == StudioTheme.textPrimary)
    }

    @Test func onlyTheTopReasoningLevelIsViolet() {
        let five = AskReasoningEffort.levels, three = AskReasoningEffort.defaultLevels
        let secondary = StudioTheme.textSecondary
        #expect(AskTheme.reasoningText(.max, in: five, defaultColor: secondary) == AskTheme.reasoningTopText)
        // Whatever the model's highest level is, it is violet.
        #expect(AskTheme.reasoningText(.high, in: three, defaultColor: secondary) == AskTheme.reasoningTopText)
        #expect(AskReasoningEffort.high.isTop(in: three) && !AskReasoningEffort.high.isTop(in: five))
        #expect(!AskReasoningEffort.providerDefault.isTop(in: [.providerDefault]))
        #expect(AskTheme.reasoningText(.providerDefault, in: five, defaultColor: StudioTheme.textSecondary)
            == StudioTheme.textSecondary)
        for effort in [AskReasoningEffort.low, .medium, .high, .xhigh] {
            #expect(AskTheme.reasoningText(effort, in: five, defaultColor: StudioTheme.textSecondary) == AskTheme.accentText)
        }
    }

    @Test func chipsMatchTheOtherFooterControls() {
        #expect(AskContextChips.chipSize == AskMetrics.composerControlHeight)
        #expect(AskContextChips.appTileSize < AskContextChips.chipSize)
    }

    @Test func switchedOffSelectionStaysInTheDraftButIsNotSent() {
        var draft = AskDraft(text: "explain", selection: "let x = 1")
        #expect(draft.request(deviceId: "device", tools: []).selection == "let x = 1")
        draft.selectionOff = true
        #expect(draft.selection == "let x = 1")
        #expect(draft.sentSelection == nil)
        #expect(draft.request(deviceId: "device", tools: []).selection == nil)
        draft.selectionOff = nil
        #expect(draft.request(deviceId: "device", tools: []).selection == "let x = 1")
    }

    @Test func selectionToggleSurvivesDraftPersistence() throws {
        var draft = AskDraft(text: "q", selection: "s")
        draft.selectionOff = true
        let data = try AskCoding.encoder().encode(draft)
        let restored = try AskCoding.decoder().decode(AskDraft.self, from: data)
        #expect(restored.selectionOff == true)
        #expect(restored.sentSelection == nil)
        // Drafts saved before the toggle existed carry no such key and still send their selection.
        let legacyData = try AskCoding.encoder().encode(AskDraft(text: "q", selection: "s"))
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("selection_off"))
        let legacy = try AskCoding.decoder().decode(AskDraft.self, from: legacyData)
        #expect(legacy.sentSelection == "s")
    }

    @Test func menuCornerIsConcentricWithItsRows() {
        // The design board's menu: 18pt card corners around 10pt rows inset 6pt.
        #expect(AskGlassCardSurface<EmptyView>.corner(.menu, style: .liquidGlass) == 18)
        #expect(AskPopoverRow<EmptyView>.corner(style: .liquidGlass) == 10)
        for style in InterfaceStyle.allCases {
            let menu = AskGlassCardSurface<EmptyView>.corner(.menu, style: style)
            #expect(AskPopoverRow<EmptyView>.corner(style: style) + 6 <= menu)
            #expect(AskGlassCardSurface<EmptyView>.corner(.hoverCard, style: style) < menu)
        }
    }

    @Test func modelRowsShowOnlyImageCapability() {
        let plain = RegisteredModel(id: "a", name: "A")
        #expect(AskModelCapabilities.badges(plain).isEmpty)
        let both = RegisteredModel(id: "b", name: "B", vision: true, reasoning: true)
        #expect(AskModelCapabilities.badges(both).map(\.help) == [L("ask.models.supportsImages")])
        let vision = RegisteredModel(id: "c", name: "C", vision: true, reasoning: false)
        #expect(AskModelCapabilities.badges(vision).map(\.help) == [L("ask.models.supportsImages")])
        // Reasoning alone earns no badge: nearly every model reasons.
        #expect(AskModelCapabilities.badges(RegisteredModel(id: "d", name: "D", vision: false, reasoning: true)).isEmpty)
    }

    @Test func settingsAndContextRecedeWhileRecording() {
        #expect(AskComposer.recordingDim(true) == 0.4)
        #expect(AskComposer.recordingDim(false) == 1)
    }
}
