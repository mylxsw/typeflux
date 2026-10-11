import CoreGraphics
import Foundation

extension ScreenshotAnnotationTool {
    /// What the size slider ranges over for this tool.
    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .rect, .ellipse, .line, .arrow, .pen: 1...16
        case .highlighter: 8...36
        case .text: 10...64
        case .counter: 18...44
        case .mosaic: 8...60
        }
    }

    /// How much `[` and `]` change the size.
    var sizeStep: CGFloat {
        switch self {
        case .rect, .ellipse, .line, .arrow, .pen: 1
        case .highlighter, .text, .counter, .mosaic: 2
        }
    }

    /// The style a tool starts with before the user changes it.
    var defaultStyle: ScreenshotAnnotationStyle {
        switch self {
        case .rect, .ellipse, .line, .arrow, .pen: ScreenshotAnnotationStyle(color: .red, size: 4)
        case .highlighter: ScreenshotAnnotationStyle(color: .yellow, size: 18)
        case .text: ScreenshotAnnotationStyle(color: .red, size: 20)
        case .counter: ScreenshotAnnotationStyle(color: .red, size: 24)
        // The color of a solid mosaic.
        case .mosaic: ScreenshotAnnotationStyle(color: .black, size: 28)
        }
    }

    /// Whether the options bar offers a color for this tool (a mosaic only when it is solid).
    var usesColor: Bool { self != .mosaic }
}

/// Each tool's own style and the mosaic options, kept between screenshots, and the colors used
/// lately. Values from storage are clamped to the tools' ranges when read.
struct ScreenshotToolStyles: Equatable, Codable {
    static let recentColorLimit = 5

    private var styles: [ScreenshotAnnotationTool: ScreenshotAnnotationStyle] = [:]
    var mosaicEffect: ScreenshotMosaic.Effect = .pixelate
    var mosaicStrength: ScreenshotMosaic.Strength = .medium
    var mosaicShape: ScreenshotAnnotationEditor.MosaicShape = .rect
    /// Most recent first; never more than `recentColorLimit`.
    private(set) var recentColors: [ScreenshotAnnotationStyle.Color] = []

    init() {}

    subscript(tool: ScreenshotAnnotationTool) -> ScreenshotAnnotationStyle {
        get { styles[tool].map { Self.normalized($0, for: tool) } ?? tool.defaultStyle }
        set { styles[tool] = Self.normalized(newValue, for: tool) }
    }

    /// Puts a color at the front of the recent colors.
    mutating func noteRecent(_ color: ScreenshotAnnotationStyle.Color) {
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.recentColorLimit {
            recentColors.removeLast(recentColors.count - Self.recentColorLimit)
        }
    }

    /// Clamps sizes, opacity and corner radius into range.
    static func normalized(_ style: ScreenshotAnnotationStyle,
                           for tool: ScreenshotAnnotationTool) -> ScreenshotAnnotationStyle {
        var style = style
        style.size = clamp(style.size, to: tool.sizeRange)
        style.opacity = clamp(style.opacity, to: ScreenshotAnnotationStyle.opacityRange)
        style.cornerRadius = clamp(style.cornerRadius, to: ScreenshotAnnotationStyle.cornerRadiusRange)
        return style
    }

    static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }

    // Tools are stored by name; unknown names and missing fields fall back to the defaults.
    private enum CodingKeys: String, CodingKey {
        case styles, mosaicEffect, mosaicStrength, mosaicShape, recentColors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let named = (try? container.decodeIfPresent([String: ScreenshotAnnotationStyle].self, forKey: .styles)) ?? [:]
        for (name, style) in named {
            guard let tool = ScreenshotAnnotationTool(rawValue: name) else { continue }
            self[tool] = style
        }
        mosaicEffect = (try? container.decodeIfPresent(ScreenshotMosaic.Effect.self, forKey: .mosaicEffect))
            ?? .pixelate
        mosaicStrength = (try? container.decodeIfPresent(ScreenshotMosaic.Strength.self, forKey: .mosaicStrength))
            ?? .medium
        mosaicShape = (try? container.decodeIfPresent(ScreenshotAnnotationEditor.MosaicShape.self,
                                                      forKey: .mosaicShape)) ?? .rect
        let recent = (try? container.decodeIfPresent([ScreenshotAnnotationStyle.Color].self,
                                                     forKey: .recentColors)) ?? []
        recentColors = Array(recent.prefix(Self.recentColorLimit))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value) }),
                             forKey: .styles)
        try container.encode(mosaicEffect, forKey: .mosaicEffect)
        try container.encode(mosaicStrength, forKey: .mosaicStrength)
        try container.encode(mosaicShape, forKey: .mosaicShape)
        try container.encode(recentColors, forKey: .recentColors)
    }
}

/// Where the tool styles are kept: shared by the region overlay and the long image editor, so a
/// style picked in one is there in the other and in the next screenshot. Used from the main thread only.
final class ScreenshotToolStyleStore {
    static let defaultsKey = "screenshot.toolStyles.json"

    private let defaults: UserDefaults?
    private let key: String

    var styles: ScreenshotToolStyles {
        didSet {
            guard styles != oldValue, let defaults, let data = try? JSONEncoder().encode(styles) else { return }
            defaults.set(String(data: data, encoding: .utf8), forKey: key)
        }
    }

    /// - Parameter defaults: nil keeps the styles in memory only, as tests do.
    init(defaults: UserDefaults? = nil, key: String = ScreenshotToolStyleStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        styles = defaults?.string(forKey: key)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ScreenshotToolStyles.self, from: $0) } ?? ScreenshotToolStyles()
    }
}
