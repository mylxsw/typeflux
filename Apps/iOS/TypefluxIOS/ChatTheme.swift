import SwiftUI
import UIKit

/// Design v4 tokens. Accent, the top reasoning violet and the accent text match the
/// Mac `AskTheme`; the canvas and fills follow iOS grouped surfaces.
enum ChatTheme {
    static let accent = dynamic(light: (0.18, 0.43, 0.94), dark: (0.09, 0.55, 1))
    static let accentText = dynamic(light: (0.106, 0.341, 0.839), dark: (0.557, 0.741, 1))
    static let accentSoft = dynamic(light: (0.902, 0.933, 0.992), dark: (0.082, 0.149, 0.243))
    static let purple = dynamic(light: (0.49, 0.25, 0.94), dark: (0.71, 0.55, 1))
    /// The page behind everything.
    static let background = dynamic(light: (0.961, 0.961, 0.969), dark: (0.059, 0.059, 0.071))
    /// Solid cards on the canvas: tool cards, tables, settings groups.
    static let card = dynamic(light: (1, 1, 1), dark: (0.110, 0.110, 0.129))
    static let codeBackground = dynamic(light: (0.949, 0.953, 0.965), dark: (0.094, 0.094, 0.114))
    static let bubble = dynamic(light: (0.894, 0.929, 0.992), dark: (0.118, 0.200, 0.341))
    static let bubbleText = dynamic(light: (0.063, 0.137, 0.302), dark: (0.882, 0.922, 1))
    static let success = dynamic(light: (0.188, 0.694, 0.345), dark: (0.196, 0.843, 0.294))
    /// Translucent neutral fills: search fields, chips, slider tracks, table headers.
    static let fill = translucent(light: 0.10, dark: 0.20)
    static let strongFill = translucent(light: 0.16, dark: 0.28)
    static let glassTint = Color(uiColor: UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.173, green: 0.173, blue: 0.204, alpha: 0.72)
            : UIColor(white: 1, alpha: 0.74)
    })
    static let glow = [
        dynamic(light: (0.18, 0.43, 0.94), dark: (0.09, 0.55, 1)),
        dynamic(light: (0.55, 0.36, 0.96), dark: (0.49, 0.23, 0.93)),
        dynamic(light: (1, 0.70, 0.28), dark: (0.98, 0.45, 0.09))
    ]
    /// UIKit may resolve dynamic colors off the main actor when appearance changes.
    static let border = Color(uiColor: UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.black.withAlphaComponent(0.08)
    })
    static let separator = border
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let textSecondary = secondary
    static let textTertiary = tertiary
    // Older names kept for the shared components.
    static let raised = card
    static let raisedSurface = card
    static let controlSurface = fill
    static let popover = card
    static let surface = background

    private static func dynamic(
        // RGB triplets keep the values directly comparable with the Mac design tokens.
        // swiftlint:disable:next large_tuple
        light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(uiColor: UIColor { @Sendable traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    private static func translucent(light: CGFloat, dark: CGFloat) -> Color {
        Color(uiColor: UIColor { @Sendable traits in
            UIColor(red: 0.47, green: 0.47, blue: 0.50,
                    alpha: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// Floating layers only: top bar buttons, the composer, popover cards, the sidebar.
/// iOS 26 uses system Liquid Glass; earlier systems and Reduce Transparency fall
/// back to a frosted or solid surface with the same outline.
private struct ChatGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    var interactive: Bool
    var reduceTransparencyOverride: Bool?
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private var reduceTransparency: Bool {
        reduceTransparencyOverride ?? systemReduceTransparency
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(ChatTheme.card))
                .overlay(shape.strokeBorder(ChatTheme.border, lineWidth: 0.5))
        } else if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(shape.fill(.regularMaterial).overlay(shape.fill(ChatTheme.glassTint)))
                .overlay(shape.strokeBorder(ChatTheme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        }
    }
}

extension View {
    /// The override supports deterministic previews; production follows system settings.
    func chatGlass(corner: CGFloat = 26, interactive: Bool = false, reduceTransparency: Bool? = nil) -> some View {
        modifier(ChatGlass(shape: RoundedRectangle(cornerRadius: corner, style: .continuous),
                           interactive: interactive, reduceTransparencyOverride: reduceTransparency))
    }

    func chatGlassCircle(interactive: Bool = false) -> some View {
        modifier(ChatGlass(shape: Circle(), interactive: interactive, reduceTransparencyOverride: nil))
    }

    /// A solid card on the canvas with a hairline outline.
    func chatCard(corner: CGFloat = 18) -> some View {
        background(ChatTheme.card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(ChatTheme.border, lineWidth: 0.5))
    }
}

/// The soft blue, violet and amber light behind the canvas, as on the Mac window.
struct ChatAmbientBackground: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                ChatTheme.background
                RadialGradient(colors: [ChatTheme.glow[0].opacity(0.14), .clear],
                               center: UnitPoint(x: 0.2, y: 0), startRadius: 0, endRadius: width * 0.95)
                RadialGradient(colors: [ChatTheme.glow[1].opacity(0.11), .clear],
                               center: UnitPoint(x: 0.92, y: 0.08), startRadius: 0, endRadius: width * 0.85)
                RadialGradient(colors: [ChatTheme.glow[2].opacity(0.08), .clear],
                               center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: width * 1.05)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
