import CoreGraphics
import Foundation

/// How one annotation looks. Each tool keeps its own style (`ScreenshotToolStyles`), and every
/// annotation carries a copy of the style it was drawn with, so changing a tool's style later
/// leaves what is already drawn alone. Fields a kind has no use for are ignored when it is drawn.
struct ScreenshotAnnotationStyle: Equatable, Codable {
    /// An sRGB color: one of the presets, or one picked from the screenshot.
    struct Color: Hashable, Codable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        init(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
        }

        /// `0xRRGGBB`.
        init(hex: UInt32) {
            self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                      blue: CGFloat(hex & 0xFF) / 255)
        }

        static let red = Color(hex: 0xFF4D4F)
        static let orange = Color(hex: 0xFF8A1F)
        static let yellow = Color(hex: 0xFFB020)
        static let green = Color(hex: 0x29C76E)
        static let teal = Color(hex: 0x1FC7C1)
        static let blue = Color(hex: 0x2F8CFF)
        static let purple = Color(hex: 0x8C5CFF)
        static let pink = Color(hex: 0xFF4FA3)
        static let white = Color(hex: 0xFFFFFF)
        static let black = Color(hex: 0x1D1D1F)

        /// The swatches of the color panel, in the order of the 1–0 keys.
        static let presets: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .white, .black]
        private static let presetNames = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink",
                                          "white", "black"]

        /// "red" for the red preset, for its localized name; nil for a picked color.
        var presetName: String? {
            Self.presets.firstIndex(of: self).map { Self.presetNames[$0] }
        }

        /// A pixel picked from the screenshot.
        init(_ pixel: ScreenshotMagnifier.RGB) {
            self.init(red: CGFloat(pixel.red) / 255, green: CGFloat(pixel.green) / 255,
                      blue: CGFloat(pixel.blue) / 255)
        }

        var rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) { (red, green, blue) }

        func cgColor(alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }

        /// "#2F8CFF".
        var hex: String {
            String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
                   Int((blue * 255).rounded()))
        }

        /// Relative luminance (WCAG), 0 for black to 1 for white.
        var luminance: CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// Dark text on light colors such as white and yellow, white text on the rest.
        var contrastingTextColor: CGColor {
            luminance > 0.5
                ? CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    enum Dash: String, CaseIterable, Codable {
        case solid, dashed
    }

    /// The inside of rectangles and ellipses.
    enum Fill: String, CaseIterable, Codable {
        /// Only the outline.
        case stroke
        /// A translucent wash of the color inside the outline.
        case soft
        /// Filled with the color, covering what is under it.
        case solid
    }

    enum ArrowHead: String, CaseIterable, Codable {
        /// Two strokes, like a chevron.
        case open
        /// A filled triangle.
        case filled
        /// Filled heads at both ends.
        case double
    }

    enum ArrowPath: String, CaseIterable, Codable {
        case straight
        /// A quadratic curve bowed by `arrowBend`.
        case curve
        /// One right angle; the sign of `arrowBend` picks which way it turns.
        case elbow
    }

    enum HighlighterMode: String, CaseIterable, Codable {
        /// A straight stroke from where the press started.
        case straight
        /// Wherever the pointer goes.
        case free
    }

    enum HighlighterTip: String, CaseIterable, Codable {
        case square, round
    }

    enum TextFont: String, CaseIterable, Codable {
        case system, rounded, serif, mono
    }

    enum TextStyle: String, CaseIterable, Codable {
        /// Colored text.
        case plain
        /// Text on a block of the color.
        case background
        /// White text outlined in the color.
        case outline
    }

    enum CounterLabel: String, CaseIterable, Codable {
        /// 1, 2, 3…
        case number
        /// A, B, C… then AA, AB…
        case letter
    }

    /// The end of a callout's line, on the thing it points at.
    enum CalloutAnchor: String, CaseIterable, Codable {
        case dot, arrow
        /// Just the line.
        case plain
    }

    enum CounterShape: String, CaseIterable, Codable {
        case circle
        /// A circle with a point, aimed by `counterAngle`.
        case bubble
    }

    var color: Color = .red
    /// Multiplies the color's alpha, 0.2...1.
    var opacity: CGFloat = 1
    /// The tool's one size: the line width of shapes, lines, arrows and the pen, the stroke
    /// of the highlighter, the font size of text and the diameter of counters.
    var size: CGFloat = 4
    var dash: Dash = .solid
    var fill: Fill = .stroke
    /// Rectangles only.
    var cornerRadius: CGFloat = 0
    var arrowHead: ArrowHead = .filled
    var arrowPath: ArrowPath = .straight
    /// How far a curved arrow bows, as a fraction of its length; for an elbow, which way it turns.
    var arrowBend: CGFloat = 0
    /// A white outline under arrows, so they show on any background.
    var outlined = false
    /// Pen strokes are smoothed when the press ends.
    var smoothed = false
    var highlighterMode: HighlighterMode = .free
    var highlighterTip: HighlighterTip = .round
    var font: TextFont = .system
    var textStyle: TextStyle = .plain
    var counterLabel: CounterLabel = .number
    var counterShape: CounterShape = .circle
    /// Where a bubble counter points, in radians from the +x axis (y grows downward).
    var counterAngle: CGFloat = .pi / 4
    /// The number (or letter) of the first counter; counters count on from it.
    var counterStart = 1
    var calloutAnchor: CalloutAnchor = .dot

    static let opacityRange: ClosedRange<CGFloat> = 0.2...1
    static let counterStartRange: ClosedRange<Int> = 1...99
    /// How much a new curved arrow bows.
    static let defaultCurveBend: CGFloat = 0.3
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...24
    static let highlighterAlpha: CGFloat = 0.4
    /// How opaque the inside of a `.soft` shape is.
    static let softFillAlpha: CGFloat = 0.28

    var lineWidth: CGFloat { size }
    var highlighterWidth: CGFloat { size }
    var fontSize: CGFloat { size }
    var counterDiameter: CGFloat { size }
    /// How wide a mosaic brush paints.
    var brushWidth: CGFloat { size }

    /// The color as drawn, with the style's opacity.
    func cgColor(alpha: CGFloat = 1) -> CGColor {
        color.cgColor(alpha: alpha * opacity)
    }

    /// Dash lengths for a line of `width`: long enough to read as dashes with round caps.
    static func dashLengths(lineWidth width: CGFloat) -> [CGFloat] {
        [max(width * 3, 4), max(width * 2.4, 4)]
    }

    init(color: Color = .red, opacity: CGFloat = 1, size: CGFloat = 4, dash: Dash = .solid, fill: Fill = .stroke,
         cornerRadius: CGFloat = 0) {
        self.color = color
        self.opacity = opacity
        self.size = size
        self.dash = dash
        self.fill = fill
        self.cornerRadius = cornerRadius
    }

    // Every field is optional when decoding, so styles saved by an older version still load.
    private enum CodingKeys: String, CodingKey {
        case color, opacity, size, dash, fill, cornerRadius, arrowHead, arrowPath, arrowBend, outlined, smoothed
        case highlighterMode, highlighterTip, font, textStyle, counterLabel, counterShape, counterAngle, counterStart
        case calloutAnchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = ScreenshotAnnotationStyle()
        color = value(.color, defaults.color)
        opacity = value(.opacity, defaults.opacity)
        size = value(.size, defaults.size)
        dash = value(.dash, defaults.dash)
        fill = value(.fill, defaults.fill)
        cornerRadius = value(.cornerRadius, defaults.cornerRadius)
        arrowHead = value(.arrowHead, defaults.arrowHead)
        arrowPath = value(.arrowPath, defaults.arrowPath)
        arrowBend = value(.arrowBend, defaults.arrowBend)
        outlined = value(.outlined, defaults.outlined)
        smoothed = value(.smoothed, defaults.smoothed)
        highlighterMode = value(.highlighterMode, defaults.highlighterMode)
        highlighterTip = value(.highlighterTip, defaults.highlighterTip)
        font = value(.font, defaults.font)
        textStyle = value(.textStyle, defaults.textStyle)
        counterLabel = value(.counterLabel, defaults.counterLabel)
        counterShape = value(.counterShape, defaults.counterShape)
        counterAngle = value(.counterAngle, defaults.counterAngle)
        counterStart = value(.counterStart, defaults.counterStart)
        calloutAnchor = value(.calloutAnchor, defaults.calloutAnchor)
    }
}
