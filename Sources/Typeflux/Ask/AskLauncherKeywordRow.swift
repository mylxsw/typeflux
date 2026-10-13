import AppKit
import SwiftUI

/// Whole keyword chips and an explicit overflow menu share one bounded viewport.
struct AskLauncherKeywordRow<ChipView: View>: View {
    let chips: [AskLauncherHome.Chip]
    let selectedID: String?
    var chipView: (AskLauncherHome.Chip, Bool) -> ChipView
    var onPickOverflow: (AskLauncherHome.Chip) -> Void

    var body: some View {
        GeometryReader { geometry in
            let widths = chips.map { Self.chipWidth($0) }
            let gap: CGFloat = 6
            let available = max(0, geometry.size.width - AskLauncherSuggestions.contentInset * 2)
            let total = widths.reduce(0, +) + CGFloat(max(0, chips.count - 1)) * gap
            let overflows = total > available
            let moreWidth = ceil((L("ask.home.more") as NSString).size(withAttributes: [
                .font: NSFont.preferredFont(forTextStyle: .callout)
            ]).width) + 36
            let selected = chips.firstIndex { AskLauncherHome.Item.chip($0).id == selectedID } ?? 0
            let visible = overflows ? AskLauncherKeywordLayout.fitting(
                widths: widths, availableWidth: max(0, available - moreWidth - gap), spacing: gap, selected: selected
            ) : Array(chips.indices)
            HStack(spacing: gap) {
                ForEach(visible, id: \.self) { index in
                    let chip = chips[index]
                    chipView(chip, AskLauncherHome.Item.chip(chip).id == selectedID)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                if overflows {
                    overflowMenu(visible: visible, selected: selected, width: moreWidth)
                }
            }
            .padding(.horizontal, AskLauncherSuggestions.contentInset)
            .frame(width: geometry.size.width, height: AskLauncherSuggestions.chipRowHeight)
        }
        .frame(height: AskLauncherSuggestions.chipRowHeight)
        .accessibilityElement(children: .contain)
    }

    private func overflowMenu(visible: [Int], selected: Int, width: CGFloat) -> some View {
        Menu {
            ForEach(chips.indices.filter { !visible.contains($0) }, id: \.self) { index in
                let chip = chips[index]
                Button(chip.keyword.keyword + " " + chip.title) { onPickOverflow(chip) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(L("ask.home.more")).font(.callout)
                Image(systemName: "chevron.down").font(.footnote)
            }
            .frame(width: width, height: AskLauncherSuggestions.chipHeight)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: width, height: AskLauncherSuggestions.chipHeight)
        .focusable(false)
        .help(L("ask.home.more.help"))
        .foregroundStyle(visible.contains(selected) ? TypefluxColor.secondaryLabel.color : TypefluxColor.accent.color)
        .accessibilityLabel(L("ask.home.more.help"))
        .accessibilityValue(visible.contains(selected) ? "" : chips[selected].title)
        .accessibilityIdentifier("ask.launcher.keywords.more")
    }

    private static func chipWidth(_ chip: AskLauncherHome.Chip) -> CGFloat {
        let keywordFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
        )
        let keyword = (chip.keyword.keyword as NSString).size(withAttributes: [.font: keywordFont]).width
        let title = (chip.title as NSString).size(withAttributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout)
        ]).width
        // Keyword inset (10), text gap (6), chip insets (14), plus pixel rounding allowance.
        return ceil(keyword) + ceil(title) + 34
    }
}
