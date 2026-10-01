import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher glass")
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

    @Test func glassDropsTheIdleBorderUnlessContrastIsIncreased() {
        let border = AskTheme.floatingBorder
        #expect(AskGlassMaterial.liquidGlass.idleBorder(border, increasedContrast: false) == .clear)
        #expect(AskGlassMaterial.visualEffect.idleBorder(border, increasedContrast: false) == .clear)
        #expect(AskGlassMaterial.liquidGlass.idleBorder(border, increasedContrast: true) == border)
        #expect(AskGlassMaterial.opaque.idleBorder(border, increasedContrast: false) == border)
    }

    @Test func chipsUseTranslucentWashesSoTheyWorkOnGlass() {
        #expect(AskIconChipFace.fillColor(.neutral, hovering: false) == .clear)
        #expect(AskIconChipFace.fillColor(.unavailable, hovering: false) == .clear)
        #expect(AskIconChipFace.fillColor(.neutral, hovering: true) == AskTheme.hoverFill)
        #expect(AskIconChipFace.fillColor(.active, hovering: false) == AskTheme.accent.opacity(0.20))
        #expect(AskIconChipFace.fillColor(.active, hovering: true) == AskTheme.accent.opacity(0.30))
        #expect(AskIconChipFace.fillColor(.warning, hovering: false) == StudioTheme.warning.opacity(0.18))
        #expect(AskIconChipFace.fillColor(.warning, hovering: true) == StudioTheme.warning.opacity(0.26))
    }

    @Test func microphoneIsBorderlessUntilHoveredOrRecording() {
        #expect(AskVoiceButton.Appearance.fill(phase: .idle, hovered: false) == .clear)
        #expect(AskVoiceButton.Appearance.fill(phase: .idle, hovered: true) == AskTheme.hoverFill)
        #expect(AskVoiceButton.Appearance.fill(phase: .listening, hovered: false) == AskTheme.accent.opacity(0.22))
    }

    @Test func onlyHighReasoningIsTinted() {
        #expect(AskReasoningMenu.labelColor(.high) == AskTheme.accentText)
        for effort in [AskReasoningEffort.providerDefault, .low, .medium] {
            #expect(AskReasoningMenu.labelColor(effort) == StudioTheme.textSecondary)
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
        // Drafts saved before the toggle existed still send their selection.
        let legacy = try AskCoding.decoder().decode(AskDraft.self, from: Data(#"{"text":"q","selection":"s"}"#.utf8))
        #expect(legacy.sentSelection == "s")
    }

    @Test func popoversLetTheSystemGlassShowOnMacOS26() {
        #expect(AskPopoverSurface.fill(.liquidGlass) == .clear)
        #expect(AskPopoverSurface.fill(.visualEffect) == AskTheme.popoverSurface)
        #expect(AskPopoverSurface.fill(.opaque) == AskTheme.popoverSurface)
    }

    @Test func modelRowsShowImageAndReasoningCapabilities() {
        let plain = RegisteredModel(id: "a", name: "A")
        #expect(AskModelCapabilities.symbols(plain).isEmpty)
        let both = RegisteredModel(id: "b", name: "B", vision: true, reasoning: true)
        #expect(AskModelCapabilities.symbols(both).map(\.symbol) == ["eye", "sparkles"])
        let vision = RegisteredModel(id: "c", name: "C", vision: true, reasoning: false)
        #expect(AskModelCapabilities.symbols(vision).map(\.help) == [L("ask.models.supportsImages")])
    }
}
