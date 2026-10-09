import CoreGraphics

/// How tall the launcher's results area stays while its rows come and go.
///
/// While typing, the area keeps the tallest height it reached, so the panel does
/// not shrink and grow with every keystroke, including the empty batch between
/// queries. Once typing pauses for
/// `settleDelay` the area settles to the rows it shows: a short list never sits
/// above a large empty space. Matching rows stay at the top; the AI action remains visible at the bottom.
/// Clearing the query discards the reserve immediately.
enum AskLauncherHeightReserve {
    /// How long typing pauses before the area settles to its rows.
    static let settleDelay: Duration = .milliseconds(450)
    /// Never discard the reserve before a search finishes and typing pauses.
    static func holding(_ reserve: CGFloat, content: CGFloat) -> CGFloat {
        max(reserve, content)
    }

    /// The reserve once typing pauses: no taller than what is shown.
    static func settled(_ reserve: CGFloat, content: CGFloat) -> CGFloat {
        min(reserve, content)
    }
}
