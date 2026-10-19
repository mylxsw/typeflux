import AppKit

/// The camera housing (or the simulated island) the notch skin grows from, in points.
struct VoiceCapsuleNotchGeometry: Equatable {
    /// Horizontal center in screen coordinates.
    var midX: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// False when the island is drawn on a display without a camera housing.
    var isHardware: Bool
}

/// The screen facts placement depends on. Built from `NSScreen` in production and by hand in tests.
struct VoiceCapsuleScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var hardwareNotch: VoiceCapsuleNotchGeometry?

    /// Zero when the menu bar is hidden (full-screen apps, automatic hiding).
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    init(frame: CGRect, visibleFrame: CGRect, hardwareNotch: VoiceCapsuleNotchGeometry? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hardwareNotch = hardwareNotch
    }

    init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        var notch: VoiceCapsuleNotchGeometry?
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notch = VoiceCapsuleLayout.hardwareNotch(frame: screen.frame, safeAreaTop: top,
                                                     topLeftArea: left, topRightArea: right)
        }
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame, hardwareNotch: notch)
    }
}

/// The shape and placement a capsule uses on one screen, after notch fallback.
enum VoiceCapsuleSkin: Equatable {
    case bottomCapsule
    /// Bottom placement and window metrics, drawn with the orb and hover controls.
    case orbCapsule
    case cornerCard(VoiceCapsuleCornerEdge)
    case notchIsland(VoiceCapsuleNotchGeometry)

    var isTopAnchored: Bool { self != .bottomCapsule && self != .orbCapsule }

    var isCornerCard: Bool {
        if case .cornerCard = self { return true }
        return false
    }
}

/// The capsule phases that change a top skin's size.
enum VoiceCapsuleSizeClass: Equatable {
    case compact
    case expanded
}

/// Pure placement math for the corner card and notch island, so it can be tested without windows.
enum VoiceCapsuleLayout {
    // Bottom capsule: the original 78×35 pill, 114 wide while listening controls show.
    static let bottomHeight: CGFloat = 35
    static let bottomRestingWidth: CGFloat = 78
    static let bottomControlsWidth: CGFloat = 114

    /// Compact width for interpolated visibilities: listening controls widen the capsule,
    /// processing keeps it at rest width (its only control replaces the percentage).
    static func bottomCompactWidth(controlsVisibility: CGFloat, processingVisibility: CGFloat) -> CGFloat {
        let controls = max(0, min(1, controlsVisibility)) * (1 - max(0, min(1, processingVisibility)))
        return bottomRestingWidth + (bottomControlsWidth - bottomRestingWidth) * controls
    }

    // Corner card.
    static let cardWidth: CGFloat = 372
    static let cardCompactHeight: CGFloat = 64
    static let cardTranscriptWidth: CGFloat = cardWidth - 36
    static let cardTranscriptFontSize: CGFloat = 15
    static let cardTranscriptLineHeight: CGFloat = 22
    /// Header, transcript lines and padding.
    static func cardExpandedHeight(lines: Int) -> CGFloat {
        cardCompactHeight + 20 + cardTranscriptLineHeight * CGFloat(clampedLines(lines))
    }

    static var cardExpandedHeight: CGFloat { cardExpandedHeight(lines: maxTranscriptLines) }
    static let cardEdgeInset: CGFloat = 14
    static let cardTopSpacing: CGFloat = 10
    /// Room around the card for its shadow; the top stays tight so the window never covers the menu bar.
    static let cardGutter = NSEdgeInsets(top: 2, left: 24, bottom: 34, right: 24)

    // Notch island.
    static let earWidth: CGFloat = 96
    static let islandExpandedWidth: CGFloat = 560
    static let islandTranscriptWidth: CGFloat = islandExpandedWidth - 44
    static let islandTranscriptFontSize: CGFloat = 15.5
    static let islandTranscriptLineHeight: CGFloat = 23
    /// Transcript lines, footer and padding below the ears.
    static func islandBodyHeight(lines: Int) -> CGFloat {
        57 + islandTranscriptLineHeight * CGFloat(clampedLines(lines))
    }

    static var islandBodyHeight: CGFloat { islandBodyHeight(lines: maxTranscriptLines) }
    /// The reverse corners that blend the island into the menu bar.
    static let islandFillet: CGFloat = 8
    static let simulatedNotchWidth: CGFloat = 188
    static let simulatedNotchMinimumHeight: CGFloat = 24
    static let fullScreenSimulatedNotchHeight: CGFloat = 30
    /// Expanded skins grow with the transcript up to this many lines, then scroll.
    static let maxTranscriptLines = 3

    static func clampedLines(_ lines: Int) -> Int { max(1, min(maxTranscriptLines, lines)) }

    /// How many lines `text` wraps to in the skin's transcript area, between 1 and `maxTranscriptLines`.
    static func transcriptLines(for skin: VoiceCapsuleSkin, text: String) -> Int {
        switch skin {
        case .bottomCapsule, .orbCapsule:
            maxTranscriptLines
        case .cornerCard:
            lineCount(text, width: cardTranscriptWidth, fontSize: cardTranscriptFontSize)
        case .notchIsland:
            lineCount(text, width: islandTranscriptWidth, fontSize: islandTranscriptFontSize)
        }
    }

    static func lineCount(_ text: String, width: CGFloat, fontSize: CGFloat) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 0 else { return 1 }
        let font = NSFont.systemFont(ofSize: fontSize)
        let bounds = (trimmed as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        // Wrapped lines advance by slightly more than the font's line height; round to the nearest line.
        return clampedLines(Int((bounds.height / lineHeight).rounded()))
    }

    static func hardwareNotch(
        frame: CGRect, safeAreaTop: CGFloat, topLeftArea: CGRect, topRightArea: CGRect
    ) -> VoiceCapsuleNotchGeometry? {
        let minX = topLeftArea.maxX
        let maxX = topRightArea.minX
        guard safeAreaTop > 0, maxX > minX else { return nil }
        return VoiceCapsuleNotchGeometry(midX: (minX + maxX) / 2, width: maxX - minX, height: safeAreaTop, isHardware: true)
    }

    /// Applies the notch fallback for displays without a camera housing.
    static func skin(for preferences: VoiceCapsulePreferences, on screen: VoiceCapsuleScreenGeometry) -> VoiceCapsuleSkin {
        switch preferences.style {
        case .bottomCapsule:
            return .bottomCapsule
        case .orbCapsule:
            return .orbCapsule
        case .cornerCard:
            return .cornerCard(preferences.cornerEdge)
        case .notchIsland:
            if let notch = screen.hardwareNotch { return .notchIsland(notch) }
            switch preferences.notchFallback {
            case .simulateNotch:
                let height = screen.menuBarHeight > 0
                    ? max(simulatedNotchMinimumHeight, screen.menuBarHeight)
                    : fullScreenSimulatedNotchHeight
                return .notchIsland(VoiceCapsuleNotchGeometry(
                    midX: screen.frame.midX, width: simulatedNotchWidth, height: height, isHardware: false
                ))
            case .cornerCard:
                return .cornerCard(preferences.cornerEdge)
            case .bottomCapsule:
                return .bottomCapsule
            }
        }
    }

    /// The visible shape's size, excluding window gutters.
    static func contentSize(
        for skin: VoiceCapsuleSkin, sizeClass: VoiceCapsuleSizeClass, transcriptLines: Int = maxTranscriptLines
    ) -> CGSize {
        switch skin {
        case .bottomCapsule, .orbCapsule:
            return .zero
        case .cornerCard:
            return CGSize(width: cardWidth, height: sizeClass == .compact
                ? cardCompactHeight : cardExpandedHeight(lines: transcriptLines))
        case let .notchIsland(notch):
            let compactWidth = notch.width + earWidth * 2
            switch sizeClass {
            case .compact:
                return CGSize(width: compactWidth, height: notch.height)
            case .expanded:
                return CGSize(width: max(islandExpandedWidth, compactWidth),
                              height: notch.height + islandBodyHeight(lines: transcriptLines))
            }
        }
    }

    /// Padding between the window edge and the visible shape.
    static func gutter(for skin: VoiceCapsuleSkin) -> NSEdgeInsets {
        switch skin {
        case .bottomCapsule, .orbCapsule:
            NSEdgeInsets()
        case .cornerCard:
            cardGutter
        case .notchIsland:
            NSEdgeInsets(top: 0, left: islandFillet, bottom: 0, right: islandFillet)
        }
    }

    static func windowSize(contentSize: CGSize, skin: VoiceCapsuleSkin) -> CGSize {
        let inset = gutter(for: skin)
        return CGSize(width: contentSize.width + inset.left + inset.right,
                      height: contentSize.height + inset.top + inset.bottom)
    }

    /// The window origin that keeps the visible shape at its anchor, given the window size including gutters.
    static func windowOrigin(windowSize: CGSize, skin: VoiceCapsuleSkin, screen: VoiceCapsuleScreenGeometry) -> CGPoint {
        let inset = gutter(for: skin)
        switch skin {
        case .bottomCapsule, .orbCapsule:
            return CGPoint(x: screen.visibleFrame.midX - windowSize.width / 2, y: screen.visibleFrame.minY)
        case let .cornerCard(edge):
            // Below the menu bar, or below the screen top when the menu bar is hidden.
            let contentTop = screen.visibleFrame.maxY - cardTopSpacing
            let y = contentTop + inset.top - windowSize.height
            let x: CGFloat = switch edge {
            case .trailing: screen.visibleFrame.maxX - cardEdgeInset + inset.right - windowSize.width
            case .leading: screen.visibleFrame.minX + cardEdgeInset - inset.left
            }
            return CGPoint(x: x, y: y)
        case let .notchIsland(notch):
            return CGPoint(x: notch.midX - windowSize.width / 2, y: screen.frame.maxY - windowSize.height)
        }
    }

    /// Picks the display for the capsule. `mouseLocation` is in global screen coordinates.
    static func screenIndex(
        for choice: VoiceCapsuleScreenChoice,
        frames: [CGRect],
        mouseLocation: CGPoint,
        activeIndex: Int?
    ) -> Int? {
        guard !frames.isEmpty else { return nil }
        switch choice {
        case .main:
            return 0
        case .activeWindow:
            return activeIndex.flatMap { frames.indices.contains($0) ? $0 : nil } ?? 0
        case .mouse:
            // NSMouseInRect semantics: the top edge belongs to the screen, so a pointer
            // resting on the menu bar of a stacked display still counts.
            return frames.firstIndex { frame in
                mouseLocation.x >= frame.minX && mouseLocation.x < frame.maxX
                    && mouseLocation.y > frame.minY && mouseLocation.y <= frame.maxY
            } ?? activeIndex.flatMap { frames.indices.contains($0) ? $0 : nil } ?? 0
        }
    }
}
