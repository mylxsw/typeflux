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

    @Test func chipsUseTranslucentWashesSoTheyWorkOnGlass() {
        #expect(AskIconChipFace.fillColor(.neutral, hovering: false) == .clear)
        #expect(AskIconChipFace.fillColor(.unavailable, hovering: false) == .clear)
        #expect(AskIconChipFace.fillColor(.neutral, hovering: true) == AskTheme.hoverFill)
        #expect(AskIconChipFace.fillColor(.active, hovering: false) == AskTheme.accent.opacity(0.20))
        #expect(AskIconChipFace.fillColor(.active, hovering: true) != AskIconChipFace.fillColor(.active, hovering: false))
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

    @Test func recordingHighlightLapsTheEdge() {
        #expect(AskVoiceBorder.sheenAngle(at: 0) == 0)
        #expect(AskVoiceBorder.sheenAngle(at: AskVoiceBorder.sheenPeriod / 2) == 180)
        #expect(AskVoiceBorder.sheenAngle(at: AskVoiceBorder.sheenPeriod) == 0)
        for step in 0..<20 {
            let angle = AskVoiceBorder.sheenAngle(at: Double(step) * 0.37)
            #expect(angle >= 0 && angle < 360)
        }
    }

    @Test func chipsMatchTheOtherFooterControls() {
        #expect(AskContextChips.chipSize == AskMetrics.composerControlHeight)
        #expect(AskContextChips.appTileSize < AskContextChips.chipSize)
    }
}
