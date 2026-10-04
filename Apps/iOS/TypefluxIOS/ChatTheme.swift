import SwiftUI
import UIKit

/// The mobile Ask surfaces use the same neutral hierarchy and blue as the Mac.
enum ChatTheme {
    static let accent = dynamic(light: (0.18, 0.43, 0.94), dark: (0.09, 0.55, 1))
    static let background = dynamic(light: (0.985, 0.985, 0.985), dark: (0.122, 0.122, 0.122))
    static let card = dynamic(light: (1, 1, 1), dark: (0.180, 0.180, 0.180))
    static let raised = dynamic(light: (0.965, 0.965, 0.965), dark: (0.150, 0.150, 0.150))
    static let sidebar = dynamic(light: (0.940, 0.940, 0.940), dark: (0.075, 0.075, 0.075))
    static let controlSurface = dynamic(light: (0.925, 0.925, 0.925), dark: (0.180, 0.180, 0.180))
    static let popover = dynamic(light: (1, 1, 1), dark: (0.196, 0.196, 0.196))
    static let accentText = dynamic(light: (0.106, 0.341, 0.839), dark: (0.557, 0.741, 1))
    static let accentSoft = dynamic(light: (0.906, 0.937, 1), dark: (0.082, 0.149, 0.243))
    static let purple = dynamic(light: (0.49, 0.25, 0.94), dark: (0.71, 0.55, 1))
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor(red: 0.886, green: 0.898, blue: 0.918, alpha: 1)
    })
    static let separator = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor(red: 0.910, green: 0.922, blue: 0.937, alpha: 1)
    })
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let surface = background
    static let raisedSurface = raised
    static let textSecondary = secondary
    static let textTertiary = tertiary

    private static func dynamic(
        // RGB triplets keep the values directly comparable with the Mac design tokens.
        // swiftlint:disable:next large_tuple
        light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

private struct ChatGlass: ViewModifier {
    var corner: CGFloat
    var reduceTransparencyOverride: Bool?
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private var reduceTransparency: Bool {
        reduceTransparencyOverride ?? systemReduceTransparency
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(ChatTheme.card)
                } else {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(ChatTheme.card.opacity(0.55)))
                }
            }
            .overlay(shape.strokeBorder(ChatTheme.border, lineWidth: 0.75))
    }
}

extension View {
    /// The override supports deterministic previews; production follows system settings.
    func chatGlass(corner: CGFloat = 28, reduceTransparency: Bool? = nil) -> some View {
        modifier(ChatGlass(corner: corner, reduceTransparencyOverride: reduceTransparency))
    }
}
