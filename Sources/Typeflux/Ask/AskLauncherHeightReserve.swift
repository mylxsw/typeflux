import CoreGraphics

/// How tall the launcher's results area stays while its rows come and go.
///
/// While typing, the area keeps the tallest height it reached, so the panel does
/// not shrink and grow with every keystroke. That kept space is capped at
/// `maximumSlack` below the current rows, and once typing pauses for
/// `settleDelay` the area settles to the rows it shows: a short list never sits
/// above a large empty space. Rows are pinned to the top, so shrinking only
/// removes space below them and never moves a row under the pointer.
enum AskLauncherHeightReserve {
    /// The most empty space kept below the rows while typing: about two result rows.
    static let maximumSlack: CGFloat = 96
    /// How long typing pauses before the area settles to its rows.
    static let settleDelay: Duration = .milliseconds(450)
    /// How long the card takes to shrink once it settles.
    static let settleAnimation: Double = 0.18

    /// The area's height while typing: never shorter than `content`, holding an
    /// earlier `reserve` up to `maximumSlack` more.
    static func holding(_ reserve: CGFloat, content: CGFloat) -> CGFloat {
        min(max(reserve, content), content + maximumSlack)
    }

    /// The reserve once typing pauses: no taller than what is shown.
    static func settled(_ reserve: CGFloat, content: CGFloat) -> CGFloat {
        min(reserve, content)
    }
}
