import AppKit
import Testing
@testable import Typeflux

struct VoiceCapsuleLayoutTests {
    /// A 1512×982 laptop screen with a 37pt menu bar and a 200pt camera housing.
    private let notched = VoiceCapsuleScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875),
        hardwareNotch: VoiceCapsuleNotchGeometry(midX: 756, width: 200, height: 37, isHardware: true)
    )
    /// An external 2560×1440 display to the right, with a 25pt menu bar and no notch.
    private let external = VoiceCapsuleScreenGeometry(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    private func preferences(
        _ style: VoiceCapsuleStyle,
        edge: VoiceCapsuleCornerEdge = .trailing,
        fallback: VoiceCapsuleNotchFallback = .simulateNotch
    ) -> VoiceCapsulePreferences {
        var preferences = VoiceCapsulePreferences()
        preferences.style = style
        preferences.cornerEdge = edge
        preferences.notchFallback = fallback
        return preferences
    }

    @Test func menuBarHeightIsTheGapAboveTheVisibleFrame() {
        #expect(notched.menuBarHeight == 37)
        #expect(external.menuBarHeight == 25)
        let fullScreen = VoiceCapsuleScreenGeometry(frame: external.frame, visibleFrame: external.frame)
        #expect(fullScreen.menuBarHeight == 0)
    }

    @Test func hardwareNotchSpansTheGapBetweenTheAuxiliaryAreas() throws {
        let notch = try #require(VoiceCapsuleLayout.hardwareNotch(
            frame: notched.frame, safeAreaTop: 37,
            topLeftArea: CGRect(x: 0, y: 945, width: 656, height: 37),
            topRightArea: CGRect(x: 856, y: 945, width: 656, height: 37)
        ))
        #expect(notch == VoiceCapsuleNotchGeometry(midX: 756, width: 200, height: 37, isHardware: true))
    }

    @Test func hardwareNotchRequiresATopInsetAndAGap() {
        let left = CGRect(x: 0, y: 945, width: 756, height: 37)
        let right = CGRect(x: 756, y: 945, width: 756, height: 37)
        #expect(VoiceCapsuleLayout.hardwareNotch(frame: notched.frame, safeAreaTop: 37, topLeftArea: left,
                                                 topRightArea: right) == nil)
        #expect(VoiceCapsuleLayout.hardwareNotch(frame: notched.frame, safeAreaTop: 0,
                                                 topLeftArea: CGRect(x: 0, y: 0, width: 600, height: 1),
                                                 topRightArea: CGRect(x: 900, y: 0, width: 600, height: 1)) == nil)
    }

    @Test func bottomAndCornerStylesIgnoreTheNotch() {
        #expect(VoiceCapsuleLayout.skin(for: preferences(.bottomCapsule), on: notched) == .bottomCapsule)
        #expect(VoiceCapsuleLayout.skin(for: preferences(.cornerCard, edge: .leading), on: notched) == .cornerCard(.leading))
        #expect(VoiceCapsuleLayout.skin(for: preferences(.cornerCard), on: external) == .cornerCard(.trailing))
    }

    @Test func notchIslandUsesTheHardwareNotchWhenPresent() {
        let skin = VoiceCapsuleLayout.skin(for: preferences(.notchIsland, fallback: .bottomCapsule), on: notched)
        #expect(skin == .notchIsland(VoiceCapsuleNotchGeometry(midX: 756, width: 200, height: 37, isHardware: true)))
    }

    @Test func notchIslandFallsBackOnDisplaysWithoutANotch() {
        let simulated = VoiceCapsuleLayout.skin(for: preferences(.notchIsland), on: external)
        #expect(simulated == .notchIsland(VoiceCapsuleNotchGeometry(
            midX: external.frame.midX, width: VoiceCapsuleLayout.simulatedNotchWidth, height: 25, isHardware: false
        )))
        #expect(VoiceCapsuleLayout.skin(for: preferences(.notchIsland, edge: .leading, fallback: .cornerCard),
                                        on: external) == .cornerCard(.leading))
        #expect(VoiceCapsuleLayout.skin(for: preferences(.notchIsland, fallback: .bottomCapsule), on: external)
            == .bottomCapsule)
    }

    @Test func simulatedNotchKeepsAMinimumHeight() {
        let thinMenuBar = VoiceCapsuleScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                     visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 790))
        let fullScreen = VoiceCapsuleScreenGeometry(frame: thinMenuBar.frame, visibleFrame: thinMenuBar.frame)
        guard case let .notchIsland(thin) = VoiceCapsuleLayout.skin(for: preferences(.notchIsland), on: thinMenuBar),
              case let .notchIsland(hidden) = VoiceCapsuleLayout.skin(for: preferences(.notchIsland), on: fullScreen)
        else {
            Issue.record("Expected simulated islands")
            return
        }
        #expect(thin.height == VoiceCapsuleLayout.simulatedNotchMinimumHeight)
        #expect(hidden.height == VoiceCapsuleLayout.fullScreenSimulatedNotchHeight)
    }

    @Test func topAnchoredSkins() {
        #expect(!VoiceCapsuleSkin.bottomCapsule.isTopAnchored)
        #expect(VoiceCapsuleSkin.cornerCard(.trailing).isTopAnchored)
        #expect(VoiceCapsuleSkin.notchIsland(notched.hardwareNotch!).isTopAnchored)
    }

    @Test func bottomCapsuleKeepsTheOriginalSizes() {
        #expect(VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: 0, processingVisibility: 0) == 78)
        #expect(VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: 1, processingVisibility: 0) == 114)
        #expect(VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: 0.5, processingVisibility: 0) == 96)
        // Processing keeps the rest width; its single control replaces the percentage.
        #expect(VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: 1, processingVisibility: 1) == 78)
        #expect(VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: 3, processingVisibility: -1) == 114)
        #expect(VoiceCapsuleLayout.bottomHeight == 35)
    }

    @Test func cardSizes() {
        let skin = VoiceCapsuleSkin.cornerCard(.trailing)
        #expect(VoiceCapsuleLayout.contentSize(for: skin, sizeClass: .compact) == CGSize(width: 372, height: 64))
        #expect(VoiceCapsuleLayout.contentSize(for: skin, sizeClass: .expanded) == CGSize(width: 372, height: 176))
        #expect(VoiceCapsuleLayout.windowSize(contentSize: CGSize(width: 372, height: 64), skin: skin)
            == CGSize(width: 420, height: 100))
        #expect(VoiceCapsuleLayout.contentSize(for: .bottomCapsule, sizeClass: .expanded) == .zero)
    }

    @Test func islandSizesGrowFromTheNotch() {
        let notch = notched.hardwareNotch!
        let skin = VoiceCapsuleSkin.notchIsland(notch)
        #expect(VoiceCapsuleLayout.contentSize(for: skin, sizeClass: .compact) == CGSize(width: 392, height: 37))
        #expect(VoiceCapsuleLayout.contentSize(for: skin, sizeClass: .expanded) == CGSize(width: 560, height: 163))
        #expect(VoiceCapsuleLayout.windowSize(contentSize: CGSize(width: 392, height: 37), skin: skin)
            == CGSize(width: 408, height: 37))
        // A wide housing keeps both ears when expanded.
        var wide = notch
        wide.width = 420
        #expect(VoiceCapsuleLayout.contentSize(for: .notchIsland(wide), sizeClass: .expanded).width == 612)
    }

    @Test func transcriptHeightFollowsTheWrappedLineCount() {
        let card = VoiceCapsuleSkin.cornerCard(.trailing)
        let island = VoiceCapsuleSkin.notchIsland(notched.hardwareNotch!)
        #expect(VoiceCapsuleLayout.transcriptLines(for: card, text: "") == 1)
        #expect(VoiceCapsuleLayout.transcriptLines(for: card, text: "   \n ") == 1)
        #expect(VoiceCapsuleLayout.transcriptLines(for: card, text: "Short note") == 1)
        let paragraph = String(repeating: "A longer dictated sentence keeps wrapping. ", count: 4)
        #expect(VoiceCapsuleLayout.transcriptLines(for: card, text: paragraph) == 3)
        #expect(VoiceCapsuleLayout.transcriptLines(for: card, text: String(repeating: paragraph, count: 10)) == 3)
        // The island is wider, so the same text needs fewer lines.
        let medium = String(repeating: "Wrap me ", count: 6)
        #expect(VoiceCapsuleLayout.transcriptLines(for: island, text: medium)
            < VoiceCapsuleLayout.transcriptLines(for: card, text: medium))
        #expect(VoiceCapsuleLayout.transcriptLines(for: .bottomCapsule, text: "x") == 3)
        #expect(VoiceCapsuleLayout.lineCount("x", width: 0, fontSize: 15) == 1)

        #expect(VoiceCapsuleLayout.cardExpandedHeight(lines: 1) == 132)
        #expect(VoiceCapsuleLayout.cardExpandedHeight(lines: 9) == VoiceCapsuleLayout.cardExpandedHeight)
        #expect(VoiceCapsuleLayout.islandBodyHeight(lines: 0) == 80)
        #expect(VoiceCapsuleLayout.contentSize(for: card, sizeClass: .expanded, transcriptLines: 2).height == 154)
        #expect(VoiceCapsuleLayout.contentSize(for: island, sizeClass: .expanded, transcriptLines: 1)
            == CGSize(width: 560, height: 37 + 80))
    }

    @Test func cornerCardSitsBelowTheMenuBarInEitherCorner() {
        let size = CGSize(width: 420, height: 100)
        let trailing = VoiceCapsuleLayout.windowOrigin(windowSize: size, skin: .cornerCard(.trailing), screen: notched)
        // Content's right edge 14pt from the screen edge, content top 10pt below the menu bar.
        let trailingEdge: CGFloat = 1512 - 14
        let notchedTop: CGFloat = 945 - 10
        #expect(trailing.x + size.width - VoiceCapsuleLayout.cardGutter.right == trailingEdge)
        #expect(trailing.y + size.height - VoiceCapsuleLayout.cardGutter.top == notchedTop)
        let leading = VoiceCapsuleLayout.windowOrigin(windowSize: size, skin: .cornerCard(.leading), screen: external)
        let leadingEdge: CGFloat = 1512 + 14
        let externalTop: CGFloat = 1415 - 10
        #expect(leading.x + VoiceCapsuleLayout.cardGutter.left == leadingEdge)
        #expect(leading.y + size.height - VoiceCapsuleLayout.cardGutter.top == externalTop)
    }

    @Test func islandHangsFromTheScreenTopAroundTheNotch() {
        let size = CGSize(width: 408, height: 37)
        let origin = VoiceCapsuleLayout.windowOrigin(windowSize: size, skin: .notchIsland(notched.hardwareNotch!),
                                                     screen: notched)
        #expect(origin == CGPoint(x: 756 - 204, y: 982 - 37))
    }

    @Test func bottomOriginCentersOnTheVisibleFrame() {
        let origin = VoiceCapsuleLayout.windowOrigin(windowSize: CGSize(width: 100, height: 40), skin: .bottomCapsule,
                                                     screen: notched)
        #expect(origin == CGPoint(x: 706, y: 70))
    }

    @Test func screenChoice() {
        let frames = [notched.frame, external.frame]
        #expect(VoiceCapsuleLayout.screenIndex(for: .main, frames: frames, mouseLocation: .zero, activeIndex: 1) == 0)
        #expect(VoiceCapsuleLayout.screenIndex(for: .activeWindow, frames: frames, mouseLocation: .zero,
                                               activeIndex: 1) == 1)
        #expect(VoiceCapsuleLayout.screenIndex(for: .activeWindow, frames: frames, mouseLocation: .zero,
                                               activeIndex: nil) == 0)
        #expect(VoiceCapsuleLayout.screenIndex(for: .activeWindow, frames: frames, mouseLocation: .zero,
                                               activeIndex: 7) == 0)
        #expect(VoiceCapsuleLayout.screenIndex(for: .mouse, frames: frames, mouseLocation: CGPoint(x: 2000, y: 300),
                                               activeIndex: 0) == 1)
        // The top edge belongs to the screen (pointer on the menu bar).
        #expect(VoiceCapsuleLayout.screenIndex(for: .mouse, frames: frames, mouseLocation: CGPoint(x: 100, y: 982),
                                               activeIndex: 1) == 0)
        // Outside every screen: the active display, then the first.
        #expect(VoiceCapsuleLayout.screenIndex(for: .mouse, frames: frames, mouseLocation: CGPoint(x: -50, y: -50),
                                               activeIndex: 1) == 1)
        #expect(VoiceCapsuleLayout.screenIndex(for: .mouse, frames: frames, mouseLocation: CGPoint(x: -50, y: -50),
                                               activeIndex: nil) == 0)
        #expect(VoiceCapsuleLayout.screenIndex(for: .mouse, frames: [], mouseLocation: .zero, activeIndex: nil) == nil)
    }

    @Test func screenGeometryReadsARealScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let geometry = VoiceCapsuleScreenGeometry(screen: screen)
        #expect(geometry.frame == screen.frame)
        #expect(geometry.visibleFrame == screen.visibleFrame)
        #expect((geometry.hardwareNotch != nil) == (screen.safeAreaInsets.top > 0))
    }

    @Test func islandShapeFlaresIntoTheMenuBarAndRoundsItsBottom() {
        let rect = CGRect(x: 0, y: 0, width: 216, height: 40)
        let path = NotchIslandShape(bottomRadius: 12, fillet: 8).path(in: rect)
        #expect(path.boundingRect == rect)
        #expect(path.contains(CGPoint(x: 108, y: 20)))
        #expect(path.contains(CGPoint(x: 6, y: 1)))            // Inside the top-left fillet.
        #expect(!path.contains(CGPoint(x: 2, y: 30)))          // Below the fillet, outside the body.
        #expect(!path.contains(CGPoint(x: 9, y: 39.5)))        // The rounded bottom-left corner.
        var shape = NotchIslandShape(bottomRadius: 1, fillet: 8)
        shape.animatableData = 20
        #expect(shape.bottomRadius == 20)
        // Degenerate sizes still produce a closed, bounded path.
        #expect(NotchIslandShape(bottomRadius: 50, fillet: 50).path(in: CGRect(x: 0, y: 0, width: 20, height: 10))
            .boundingRect.width <= 20)
    }
}
