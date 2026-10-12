/// All visible prose is supplied by the caller; the UI library owns no localization.
public struct TypefluxGalleryLabels {
    public let style: String
    public let classic: String
    public let liquidGlass: String
    public let appearance: String
    public let light: String
    public let dark: String
    public let colors: String
    public let typography: String
    public let metrics: String
    public let sampleText: String

    public init(style: String, classic: String, liquidGlass: String, appearance: String,
                light: String, dark: String, colors: String, typography: String, metrics: String, sampleText: String) {
        self.style = style
        self.classic = classic
        self.liquidGlass = liquidGlass
        self.appearance = appearance
        self.light = light
        self.dark = dark
        self.colors = colors
        self.typography = typography
        self.metrics = metrics
        self.sampleText = sampleText
    }
}
