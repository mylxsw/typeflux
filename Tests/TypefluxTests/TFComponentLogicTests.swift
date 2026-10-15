import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Pure logic behind the shared components in `UI/Components`.
@Suite("Shared component logic")
struct TFComponentLogicTests {
    @Test func controlSizesFollowTheThreeHeightScale() {
        #expect(TFControlSize.allCases.map(\.height) == [24, 30, 36])
        #expect(TFControlSize.allCases.map(\.fontSize) == [12, 13, 14])
        #expect(TFControlSize.allCases.map(\.horizontalPadding) == [10, 14, 18])
        #expect(TFControlSize.allCases.map(\.iconSize) == [11, 12, 14])
        #expect(TFControlSize.allCases.map(\.spacing) == [5, 6, 7])
        #expect(TFControlSize.small.minimumTextButtonWidth == nil)
        #expect(TFControlSize.regular.minimumTextButtonWidth == 64)
        #expect(TFControlSize.large.fontWeight == .semibold)
        #expect(TFControlSize.regular.fontWeight == .medium)
        #expect(TFControlSize.regular.segmentItemHeight == 26)
        #expect(TFControlSize.small.segmentItemHeight == 20)
        #expect(TFControlSize.small.segmentFontSize == 12)
        #expect(TFControlSize.regular.segmentFontSize == 12.5)
        #expect(TFControlSize.small.segmentHorizontalPadding == 9)
        #expect(TFControlSize.regular.segmentHorizontalPadding == 12)
        #expect(TFControlSize.large.id == "large")
    }

    @Test func containersNestConcentrically() {
        #expect(TFMetrics.cardCornerRadius - TFMetrics.menuPadding == TFMetrics.itemCornerRadius)
        #expect(TFListGroupInset.withIcon == TFMetrics.rowHorizontalPadding + TFMetrics.iconTileSize + 10)
        #expect(TFListGroupInset.plain == TFMetrics.rowHorizontalPadding)
    }

    @Test func layoutFoldsBelowTheCompactWidth() {
        #expect(TFLayout.isCompact(contentWidth: 719))
        #expect(!TFLayout.isCompact(contentWidth: 720))
        #expect(TFLayout.filterPresentation(optionCount: 4, compact: false) == .segmented)
        #expect(TFLayout.filterPresentation(optionCount: 5, compact: false) == .menu)
        #expect(TFLayout.filterPresentation(optionCount: 2, compact: true) == .menu)
        #expect(!TFLayout.menuNeedsSearch(optionCount: 12))
        #expect(TFLayout.menuNeedsSearch(optionCount: 13))
    }

    @Test func primaryButtonsUseTheAccentAndDarkenWhenPressed() {
        let rest = TFButtonAppearance.resolve(kind: .primary, destructive: false, isHovering: false, isPressed: false)
        #expect(rest == .init(fill: .accent, foreground: .onFill, overlay: .none, hasBorder: false))
        #expect(TFButtonAppearance.resolve(kind: .primary, destructive: false, isHovering: true, isPressed: false).fill == .accentHover)
        let pressed = TFButtonAppearance.resolve(kind: .primary, destructive: false, isHovering: true, isPressed: true)
        #expect(pressed.fill == .accent && pressed.overlay == .darken)
        let danger = TFButtonAppearance.resolve(kind: .primary, destructive: true, isHovering: true, isPressed: false)
        #expect(danger.fill == .danger && danger.overlay == .hover)
        #expect(TFButtonAppearance.resolve(kind: .primary, destructive: true, isHovering: false, isPressed: true).overlay == .darken)
        #expect(TFButtonAppearance.resolve(kind: .primary, destructive: true, isHovering: false, isPressed: false).overlay == .none)
    }

    @Test func otherButtonKindsResolveFillTextAndOverlay() {
        let secondary = TFButtonAppearance.resolve(kind: .secondary, destructive: false, isHovering: true, isPressed: false)
        #expect(secondary == .init(fill: .control, foreground: .primary, overlay: .hover, hasBorder: true))
        #expect(TFButtonAppearance.resolve(kind: .secondary, destructive: true, isHovering: false, isPressed: true)
            == .init(fill: .control, foreground: .danger, overlay: .pressed, hasBorder: true))
        #expect(TFButtonAppearance.resolve(kind: .plain, destructive: false, isHovering: false, isPressed: false).foreground == .secondary)
        #expect(TFButtonAppearance.resolve(kind: .plain, destructive: false, isHovering: true, isPressed: false).foreground == .primary)
        #expect(TFButtonAppearance.resolve(kind: .plain, destructive: true, isHovering: false, isPressed: false).foreground == .danger)
        let link = TFButtonAppearance.resolve(kind: .link, destructive: false, isHovering: true, isPressed: false)
        #expect(link.fill == .none && link.foreground == .accent && link.opacity == 0.78 && link.overlay == .none)
        #expect(TFButtonAppearance.resolve(kind: .link, destructive: true, isHovering: false, isPressed: false).opacity == 1)
        #expect(TFButtonAppearance.resolve(kind: .link, destructive: true, isHovering: false, isPressed: false).foreground == .danger)
        #expect(TFButtonAppearance.resolve(kind: .glass, destructive: false, isHovering: false, isPressed: true)
            == .init(fill: .glass, foreground: .primary, overlay: .pressed, hasBorder: false))
        #expect(TFButtonAppearance.resolve(kind: .glass, destructive: true, isHovering: false, isPressed: false).foreground == .danger)
        #expect(TFButtonKind.allCases.map(\.id) == ["primary", "secondary", "plain", "link", "glass"])
    }

    @Test func appearanceColorsCoverEveryCase() {
        for foreground in [TFButtonAppearance.Foreground.onFill, .primary, .secondary, .accent, .danger] {
            _ = TFButtonAppearance(fill: .none, foreground: foreground, overlay: .none, hasBorder: false).foregroundColor
        }
        let clear = TFButtonAppearance(fill: .none, foreground: .primary, overlay: .none, hasBorder: false)
        #expect(clear.overlayColor == .clear)
        for overlay in [TFButtonAppearance.Overlay.hover, .pressed, .darken] {
            #expect(TFButtonAppearance(fill: .none, foreground: .primary, overlay: overlay, hasBorder: false).overlayColor != .clear)
        }
        #expect(TFButtonAppearance(fill: .none, foreground: .onFill, overlay: .none, hasBorder: false).foregroundColor == .white)
    }

    @Test func keyboardSelectionWrapsAndRecovers() {
        #expect(TFSelectionStep.value(after: "b", in: ["a", "b", "c"], forward: true) == "c")
        #expect(TFSelectionStep.value(after: "c", in: ["a", "b", "c"], forward: true) == "a")
        #expect(TFSelectionStep.value(after: "a", in: ["a", "b", "c"], forward: false) == "c")
        #expect(TFSelectionStep.value(after: "x", in: ["a", "b"], forward: true) == "a")
        #expect(TFSelectionStep.value(after: "x", in: [String](), forward: true) == nil)
        #expect(TFMenuHighlight.move(nil, in: [1, 2, 3], down: true) == 1)
        #expect(TFMenuHighlight.move(nil, in: [1, 2, 3], down: false) == 3)
        #expect(TFMenuHighlight.move(3, in: [1, 2, 3], down: true) == 1)
        #expect(TFMenuHighlight.move(1, in: [1, 2, 3], down: false) == 3)
        #expect(TFMenuHighlight.move(9, in: [1, 2], down: true) == 1)
        #expect(TFMenuHighlight.move(1, in: [Int](), down: true) == nil)
    }

    @Test func searchMatchingIgnoresCaseWidthDiacriticsAndPadding() {
        #expect(TFSearchMatcher.matches("", "anything"))
        #expect(TFSearchMatcher.matches("   ", ["x"]))
        #expect(TFSearchMatcher.matches("CLOUD", "Typeflux Cloud"))
        #expect(TFSearchMatcher.matches(" asr ", "Alibaba", "Realtime ASR"))
        #expect(TFSearchMatcher.matches("cafe", "Café"))
        #expect(TFSearchMatcher.matches("abc", "ＡＢＣ"))
        #expect(TFSearchMatcher.matches("翻译", ["中文翻译"]))
        #expect(!TFSearchMatcher.matches("zzz", "Typeflux", "Cloud"))
        #expect(TFSearchMatcher.normalized("  hi\n") == "hi")
    }

    @Test func highlightingMarksTheFirstMatch() throws {
        let text = "Typeflux Cloud"
        let range = try #require(TFSearchMatcher.highlightRange(in: text, query: "cloud"))
        #expect(text[range] == "Cloud")
        #expect(TFSearchMatcher.highlightRange(in: text, query: " ") == nil)
        #expect(TFSearchMatcher.highlightRange(in: text, query: "zzz") == nil)
        let highlighted = TFSearchMatcher.highlighted(text, query: "cloud")
        let runs = highlighted.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(runs.count == 1)
        #expect(String(highlighted[try #require(runs.first).range].characters) == "Cloud")
        #expect(TFSearchMatcher.highlighted(text, query: "").runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test func escapeClearsBeforeLeavingTheField() {
        #expect(TFSearchEscapeAction.resolve(text: "query") == .clear)
        #expect(TFSearchEscapeAction.resolve(text: "") == .resignFocus)
    }

    @Test func richSectionsFilterAndDropEmptyGroups() {
        let sections = [
            TFRichSection("A", options: [TFRichOption(1, "Cloud", subtitle: "Default"), TFRichOption(2, "Local")]),
            TFRichSection("B", options: [TFRichOption(3, "GPT", trailing: "Set up")])
        ]
        #expect(TFRichSection.filter(sections, query: "").map(\.options.count) == [2, 1])
        #expect(TFRichSection.filter(sections, query: "default").map { $0.options.map(\.value) } == [[1]])
        #expect(TFRichSection.filter(sections, query: "set").map(\.title) == ["B"])
        #expect(TFRichSection.filter(sections, query: "zzz").isEmpty)
        #expect(sections[0].options[0].id == 1)
    }

    @Test func popUpSectionsFlattenWithHeadersSeparatorsAndTags() {
        let sections = [
            TFPopUpSection(title: "Built-in", options: [TFOption("a", "A")]),
            TFPopUpSection(options: [TFOption("b", "B", systemImage: "star", count: 3), TFOption("c", "C")])
        ]
        let entries = TFPopUpSection.entries(sections, selection: "b")
        #expect(entries.map(\.kind) == [.header, .item(tag: 0), .separator, .item(tag: 1), .item(tag: 2)])
        #expect(entries.filter(\.isSelected).map(\.title) == ["B"])
        #expect(entries[3].count == 3 && entries[3].systemImage == "star")
    }

    @Test func menuActionsMapTagsToHandlers() {
        var calls: [String] = []
        let menu = TFMenuAction.entries([
            .action("Import") { calls.append("import") },
            .separator,
            .action("Delete", systemImage: "trash", destructive: true) { calls.append("delete") }
        ])
        #expect(menu.entries.map(\.kind) == [.item(tag: 0), .separator, .item(tag: 1)])
        #expect(menu.entries[2].destructive && menu.entries[2].systemImage == "trash")
        menu.handlers[1]()
        menu.handlers[0]()
        #expect(calls == ["delete", "import"])
    }

    @Test func nativeMenusCarryHeadersChecksCountsAndDestructiveColor() throws {
        final class Target: NSObject {
            var tags: [Int] = []
            @objc func choose(_ sender: NSMenuItem) { tags.append(sender.tag) }
        }
        let target = Target()
        let entries: [TFNativeMenuEntry] = [
            .header("Group"),
            TFNativeMenuEntry(kind: .item(tag: 0), title: "All", count: 12, isSelected: true),
            .separator,
            TFNativeMenuEntry(kind: .item(tag: 1), title: "Delete", systemImage: "trash", destructive: true)
        ]
        let menu = TFNativeMenuEntry.makeMenu(entries, target: target, action: #selector(Target.choose(_:)))
        #expect(menu.items.count == 4)
        #expect(menu.items[1].state == .on && menu.items[3].state == .off)
        #expect(menu.items[1].attributedTitle?.string == "All\t12")
        #expect(menu.items[3].image != nil)
        let red = menu.items[3].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(red == .systemRed)
        #expect(menu.items[2].isSeparatorItem)
        let delete = menu.items[3]
        #expect(delete.target === target && delete.action == #selector(Target.choose(_:)) && delete.tag == 1)
        target.choose(delete)
        #expect(target.tags == [1])
        #expect(TFNativeMenuEntry.countColumn(for: entries) > 36)
        #expect(TFNativeMenuEntry.countColumn(for: []) == 36)
    }

    @Test func filterMenuIsActiveAwayFromItsDefault() {
        #expect(!TFFilterMenu<String>.isActive(selection: "all", defaultValue: "all"))
        #expect(TFFilterMenu<String>.isActive(selection: "ai", defaultValue: "all"))
    }

    @Test func optionsAndPanesExposeStableIdentity() {
        let icon = TFOption<String>.icon("grid", systemImage: "square.grid.2x2", help: "Grid")
        #expect(icon.id == "grid" && icon.title.isEmpty && icon.help == "Grid")
        let pane = TFPaneItem("web", "Web", systemImage: "globe", status: .active)
        #expect(pane.id == "web" && pane.status == .active)
        #expect(TFPaneSection("Group", items: [pane]).id == "Group")
        #expect(TFPaneSection(items: [pane]).id == "web")
    }

    @Test func iconTilesUseTheFirstLetterOrDigit() {
        #expect(TFIconTile.initial(of: "  groq") == "G")
        #expect(TFIconTile.initial(of: "1Password") == "1")
        #expect(TFIconTile.initial(of: "中文翻译") == "中")
        #expect(TFIconTile.initial(of: "—") == "")
    }

    @Test func rowHeightsFollowContentAndDensity() {
        typealias Row = TFListRow<EmptyView, EmptyView>
        #expect(Row.height(hasSubtitle: true, density: .regular) == 52)
        #expect(Row.height(hasSubtitle: false, density: .regular) == 36)
        #expect(Row.height(hasSubtitle: true, density: .compact) == 30)
    }

    @Test func statusDotsMapLevelsToColors() {
        #expect(TFStatusDot(level: .success).color == TFColors.success)
        #expect(TFStatusDot(level: .warning).color == TFColors.warning)
        #expect(TFStatusDot(level: .danger).color == TFColors.danger)
        #expect(TFStatusDot(level: .neutral).color == TFColors.textTertiary)
    }

    @Test func galleryAccessIsDebugOrExplicit() {
        #expect(ComponentGalleryAccess.isAvailable(environment: [:], arguments: [], isDebugBuild: true))
        #expect(!ComponentGalleryAccess.isAvailable(environment: [:], arguments: [], isDebugBuild: false))
        #expect(ComponentGalleryAccess.isAvailable(environment: ["TYPEFLUX_COMPONENT_GALLERY": "1"], arguments: [],
                                                   isDebugBuild: false))
        #expect(!ComponentGalleryAccess.isAvailable(environment: ["TYPEFLUX_COMPONENT_GALLERY": "0"], arguments: [],
                                                    isDebugBuild: false))
        #expect(ComponentGalleryAccess.isAvailable(environment: [:], arguments: ["app", "--component-gallery"],
                                                   isDebugBuild: false))
        #expect(ComponentGalleryAccess.opensAtLaunch(arguments: ["app", "--component-gallery"]))
        #expect(!ComponentGalleryAccess.opensAtLaunch(arguments: ["app"]))
        _ = ComponentGalleryAccess.isDebugBuild
    }

    @Test func galleryAppearancesAndSectionsAreComplete() {
        #expect(ComponentGalleryAppearance.system.nsAppearance == nil)
        #expect(ComponentGalleryAppearance.light.nsAppearance?.name == .aqua)
        #expect(ComponentGalleryAppearance.dark.nsAppearance?.name == .darkAqua)
        #expect(ComponentGalleryAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(ComponentGalleryAppearance.dark.id == "dark")
        let listed = ComponentGallerySection.paneSections.flatMap(\.items).map(\.id)
        #expect(listed == ComponentGallerySection.allCases)
        #expect(Set(ComponentGallerySection.allCases.map(\.title)).count == ComponentGallerySection.allCases.count)
        #expect(ComponentGallerySection.allCases.allSatisfy { !$0.systemImage.isEmpty && $0.id == $0.rawValue })
    }
}
