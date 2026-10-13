import SwiftUI

/// Library content stays solid; legacy floating surfaces retain their existing material.
struct AskContentCardSurface: ViewModifier {
    var corner: CGFloat
    var opaqueFill: Color
    var cornerStyle: RoundedCornerStyle = .continuous
    var elevation: AskElevation? = .panel
    var elevatedInLight = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.askUsesLibraryTokens) private var libraryTokens

    func body(content: Content) -> some View {
        if libraryTokens {
            let shape = RoundedRectangle(cornerRadius: corner, style: cornerStyle)
            content.background(TypefluxColor.controlBackground.color, in: shape)
                .overlay(shape.strokeBorder(TypefluxColor.separator.color).allowsHitTesting(false))
        } else if colorScheme == .light {
            let shape = RoundedRectangle(cornerRadius: corner, style: cornerStyle)
            content
                .background(shape.fill(.white))
                .overlay(shape.strokeBorder(AskTheme.cardBorder, lineWidth: 1).allowsHitTesting(false))
                .background {
                    if elevation != nil, elevatedInLight {
                        shape.fill(.white)
                            .shadow(color: Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255).opacity(0.04),
                                    radius: 1, y: 1)
                            .shadow(color: Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255).opacity(0.10),
                                    radius: 10, y: 4)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content.modifier(AskInWindowGlass(corner: corner, opaqueFill: opaqueFill,
                                              cornerStyle: cornerStyle, elevation: elevation))
        }
    }
}

extension View {
    func askContentCard(corner: CGFloat, opaqueFill: Color = AskTheme.glassFill,
                        elevation: AskElevation? = .panel, elevatedInLight: Bool = true) -> some View {
        modifier(AskContentCardSurface(corner: corner, opaqueFill: opaqueFill, elevation: elevation,
                                       elevatedInLight: elevatedInLight))
    }
}
