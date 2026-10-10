import AppKit
import SwiftUI

// MARK: - Elevation

/// How high a glass surface floats above the window, as drop shadows from the
/// design board: a wide soft shadow plus a tight contact shadow.
enum AskElevation: Equatable {
    /// Header pills and other small controls.
    case control
    /// The sidebar, composer, cards.
    case panel
    /// Menus and the ⌘K palette, which float above everything else.
    case popover

    struct Layer: Equatable {
        var opacity: Double
        var radius: CGFloat
        var offsetY: CGFloat
    }

    /// Shadow layers for the appearance. Light mode uses a cooler, much fainter tint.
    func layers(dark: Bool) -> [Layer] {
        switch (self, dark) {
        case (.control, true): return [
            Layer(opacity: 0.30, radius: 10, offsetY: 6),
            Layer(opacity: 0.30, radius: 1, offsetY: 1)
        ]
        case (.control, false): return [
            Layer(opacity: 0.10, radius: 9, offsetY: 5),
            Layer(opacity: 0.08, radius: 1, offsetY: 1)
        ]
        case (.panel, true): return [
            Layer(opacity: 0.38, radius: 17, offsetY: 12),
            Layer(opacity: 0.35, radius: 1, offsetY: 1)
        ]
        case (.panel, false): return [
            Layer(opacity: 0.14, radius: 15, offsetY: 10),
            Layer(opacity: 0.12, radius: 1, offsetY: 1)
        ]
        case (.popover, true): return [
            Layer(opacity: 0.45, radius: 24, offsetY: 16),
            Layer(opacity: 0.35, radius: 1, offsetY: 1)
        ]
        case (.popover, false): return [
            Layer(opacity: 0.18, radius: 22, offsetY: 14),
            Layer(opacity: 0.12, radius: 1, offsetY: 1)
        ]
        }
    }

    /// The shadow colour: neutral black in dark, a navy tint in light.
    static func shadowColor(dark: Bool) -> Color {
        dark ? .black : Color(red: 30 / 255, green: 30 / 255, blue: 60 / 255)
    }
}

/// Draws a shape's drop shadows outside it only. A plain `.shadow` on glass
/// would also shadow every label inside it, and an opaque shadow caster behind
/// translucent glass would darken the glass itself.
struct AskOuterShadow<S: Shape>: View {
    let shape: S
    let elevation: AskElevation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            ForEach(Array(elevation.layers(dark: dark).enumerated()), id: \.offset) { _, layer in
                shape.fill(Color.black)
                    .shadow(color: AskElevation.shadowColor(dark: dark).opacity(layer.opacity),
                            radius: layer.radius, x: 0, y: layer.offsetY)
            }
        }
        .mask {
            ZStack {
                Rectangle().padding(-80)
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Floats the view's glass shape with the design board's drop shadow.
    func askElevation<S: Shape>(_ elevation: AskElevation, in shape: S) -> some View {
        background(AskOuterShadow(shape: shape, elevation: elevation))
    }
}

// MARK: - Entrances

/// A floating card's entrance: it grows from its anchor with a slight lift
/// and comes into focus, on a short spring. Reduce Motion fades only.
struct AskPopIn: ViewModifier {
    var anchor: UnitPoint
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let startScale: CGFloat = 0.9
    static let startBlur: CGFloat = 4
    static let startOffset: CGFloat = 4

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.72)
    }

    func body(content: Content) -> some View {
        let moving = !shown && !reduceMotion
        content
            .scaleEffect(moving ? Self.startScale : 1, anchor: anchor)
            .offset(y: moving ? (anchor.y > 0.5 ? Self.startOffset : -Self.startOffset) : 0)
            .blur(radius: moving ? Self.startBlur : 0)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Self.animation(reduceMotion: reduceMotion)) { shown = true } }
    }
}

/// A message or tool card that has just arrived rises into place; anything
/// older (a loaded conversation, a row scrolled back into view) appears as is.
struct AskRiseIn: ViewModifier {
    let createdAt: Date?
    @State private var shown: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let freshness: TimeInterval = 3
    static let distance: CGFloat = 10

    /// Whether an item is new enough to animate in.
    static func isFresh(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < freshness
    }

    func body(content: Content) -> some View {
        let hidden = shown == false
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden && !reduceMotion ? Self.distance : 0)
            .onAppear {
                guard shown == nil else { return }
                guard Self.isFresh(createdAt) else { shown = true; return }
                shown = false
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { shown = true }
            }
    }
}

extension View {
    func askPopIn(anchor: UnitPoint) -> some View { modifier(AskPopIn(anchor: anchor)) }
    func askRiseIn(createdAt: Date?) -> some View { modifier(AskRiseIn(createdAt: createdAt)) }
}

// MARK: - Shimmer

/// A light sweep across text that is still being produced ("正在思考").
struct AskShimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let duration: Double = 1.6

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.6
                    withAnimation(.linear(duration: Self.duration).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

// MARK: - Cards

/// A card that lifts toward the pointer and gives way when pressed, on springs.
/// Classic cards stay put and answer the pointer with their fill instead.
struct AskLiftingCardStyle: ButtonStyle {
    static let hoverLift: CGFloat = 3
    static let pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        Lifting(configuration: configuration)
    }

    private struct Lifting: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.interfaceStyle) private var style

        var body: some View {
            let moves = !reduceMotion && style.usesGlass
            configuration.label
                .scaleEffect(configuration.isPressed && moves ? AskLiftingCardStyle.pressedScale : 1)
                .offset(y: hovering && isEnabled && moves ? -AskLiftingCardStyle.hoverLift : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.62), value: hovering)
                .animation(.spring(response: 0.26, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// The workspace composer's depth: the panel shadow under its glass and the
/// rim light along its edge. The launcher is its own
/// floating window and takes the system window shadow instead.
struct AskWorkspaceCardDepth: ViewModifier {
    var enabled: Bool
    var corner: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if enabled {
            content
                .background(AskOuterShadow(shape: shape, elevation: .panel))
                .overlay(shape.strokeBorder(AskRimLight.gradient(dark: colorScheme == .dark), lineWidth: 1)
                    .allowsHitTesting(false))
        } else {
            content
        }
    }
}
