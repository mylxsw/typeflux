import SwiftUI
import Testing
@testable import Typeflux

/// Pure logic behind the row, token and feedback pieces in `UI/Components/TFRows.swift`.
@Suite("Shared row component logic")
struct TFRowsLogicTests {
    @Test func flowLayoutBreaksGreedilyAndGivesWideItemsTheirOwnLine() {
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 22), CGSize(width: 40, height: 20),
                     CGSize(width: 200, height: 20), CGSize(width: 10, height: 18)]
        let rows = TFFlowLayout.rows(width: 100, sizes: sizes, spacing: 6)
        #expect(rows.map(\.indices) == [[0, 1], [2], [3], [4]])
        #expect(rows[0].width == 86 && rows[0].height == 22)
        #expect(rows[2].width == 200, "an item wider than the line is not split or dropped")
        #expect(TFFlowLayout.rows(width: 100, sizes: [], spacing: 6).isEmpty)
        #expect(TFFlowLayout.rows(width: .infinity, sizes: sizes, spacing: 6).count == 1)
    }

    @Test func tokenInputAddsOnlyNewValidValues() {
        let normalize: (String) -> String? = { text in
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            return value.isEmpty ? nil : value
        }
        #expect(TFTokenInput.adding(" MD ", to: ["swift"], normalize: normalize) == ["swift", "md"])
        #expect(TFTokenInput.adding("Swift", to: ["swift"], normalize: normalize) == nil)
        #expect(TFTokenInput.adding("   ", to: ["swift"], normalize: normalize) == nil)
    }

    @Test func meterClampsItsFraction() {
        #expect(TFMeter.fraction(1, of: 4) == 0.25)
        #expect(TFMeter.fraction(8, of: 4) == 1)
        #expect(TFMeter.fraction(-1, of: 4) == 0)
        #expect(TFMeter.fraction(3, of: 0) == 0)
    }

    @Test func fieldMessagesAndStatusDotsUseSemanticColors() {
        #expect(TFFieldMessage(text: "x").color == TFColors.danger)
        #expect(TFFieldMessage(text: "x", tone: .warning).color == TFColors.warning)
        #expect(TFFieldMessage(text: "x", tone: .hint).color == TFColors.textSecondary)
        #expect(TFStatusDot(level: .accent).color == TFColors.accent)
    }

    @Test func iconRowsLineUpTheirHairlines() {
        #expect(TFListGroupInset.formWithIcon == 14 + TFMetrics.iconTileSize + 12)
        #expect(TFMetrics.paneSpacing > TFMetrics.toolbarSpacing)
    }

    @Test func noticesUseTheirToneColorAndSymbol() {
        let tones = TFNotice.Tone.allCases.map { TFNotice(text: "x", tone: $0) }
        #expect(tones.map(\.color) == [TFColors.accent, TFColors.success, TFColors.warning, TFColors.danger])
        #expect(Set(tones.map(\.systemImage)).count == TFNotice.Tone.allCases.count)
        #expect(TFNotice(text: "x").tone == .info)
    }

    @Test func paneItemsCarryTheirStateForColorAndVoiceOver() {
        typealias Status = TFPaneItem<String>.Status
        #expect([Status.active, .inactive, .attention].map(\.level) == [.success, .neutral, .warning])
        let item = TFPaneItem("files", "Files", systemImage: "folder", status: .attention, statusLabel: "No folders")
        #expect(item.accessibilityTitle == "Files, No folders")
        #expect(TFPaneItem("a", "Alpha", systemImage: "a.circle").accessibilityTitle == "Alpha")
    }

    @Test func agentCapabilityLevelsMapToSharedStates() {
        let levels: [AgentCapabilityStatus.Level] = [.ready, .attention, .off]
        #expect(levels.map(\.statusDot) == [.success, .warning, .neutral])
        #expect(levels.map(\.paneStatus) == [.active, .attention, .inactive])
        let attention = AgentCapabilityStatus(capability: .files, level: .attention, label: "No folders").statusLabel
        #expect(attention.tintsText && attention.level == .warning && attention.text == "No folders")
        #expect(!AgentCapabilityStatus(capability: .files, level: .ready, label: "Ready").statusLabel.tintsText)
    }

    @Test func iconRowsKeepAWideControlBesideTheirText() {
        #expect(TFFormRow<EmptyView>.labelIdealWidthWithIcon == 180)
        let row = 14 + TFMetrics.iconTileSize + 12 + TFFormRow<EmptyView>.labelIdealWidthWithIcon + 16
            + TFMetrics.formControlWideWidth + 14
        #expect(row == 14 + TFFormRow<EmptyView>.labelIdealWidth + 16 + TFMetrics.formControlWideWidth + 14)
    }
}
