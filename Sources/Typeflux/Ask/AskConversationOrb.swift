import SwiftUI

/// The empty state's mark: a drop of colour that slowly changes shape while its
/// gradient flows through it, over a soft glow of the same colours. Everything
/// runs on one 8 s loop, twice as fast while the user dictates a new question.
/// Reduce Motion holds it still.
struct AskConversationOrb: View {
    var size: CGFloat = 88
    var listening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    static let period: TimeInterval = 8
    static let colors: [Color] = [
        Color(red: 0.18, green: 0.42, blue: 1.0),
        Color(red: 0.55, green: 0.36, blue: 0.96),
        Color(red: 1.0, green: 0.30, blue: 0.55),
        Color(red: 1.0, green: 0.70, blue: 0.28),
        Color(red: 0.18, green: 0.90, blue: 0.84),
        Color(red: 0.18, green: 0.42, blue: 1.0)
    ]
    /// How far the outline strays from a circle, as a share of the radius.
    static let calmWobble = 0.07
    static let listeningWobble = 0.1
    /// The frame Reduce Motion shows: a gently irregular drop rather than a circle.
    static let stillPhase = 0.15

    /// Position in the loop, in 0..<1.
    static func phase(at date: Date, listening: Bool) -> Double {
        let period = listening ? Self.period / 2 : Self.period
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// Two breaths per loop, between 1 and 1.035.
    static func breath(_ phase: Double) -> CGFloat {
        CGFloat(1 + 0.0175 * (1 - cos(4 * .pi * phase)))
    }

    /// One cycle of the palette, twice over, so a gradient sliding by one cycle wraps seamlessly.
    static let flowColors: [Color] = Array(colors.dropLast()) + colors
    /// How long one palette cycle is, in units of the drop's size.
    static let cycleLength = 2.4

    /// The gradient slides one palette cycle along its axis per loop, like a
    /// moving background, while the axis sways by ±15°. Two or three colours
    /// show at a time as a soft wash.
    static func flow(_ phase: Double) -> (start: UnitPoint, end: UnitPoint) {
        let angle = .pi / 6 + .pi / 12 * sin(2 * .pi * phase)
        let ux = cos(angle), uy = sin(angle)
        // The drop's centre sits at `offset` along the gradient, which spans two cycles.
        let offset = cycleLength * (0.5 + phase)
        let startX = 0.5 - ux * offset, startY = 0.5 - uy * offset
        return (UnitPoint(x: startX, y: startY),
                UnitPoint(x: startX + ux * 2 * cycleLength, y: startY + uy * 2 * cycleLength))
    }

    var body: some View {
        Group {
            if reduceMotion {
                drop(phase: Self.stillPhase)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    drop(phase: Self.phase(at: context.date, listening: listening))
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
        }
        .accessibilityHidden(true)
    }

    /// One frame of the drop; internal so renders can step through the loop.
    func drop(phase: Double) -> some View {
        let shape = AskFluidDropShape(phase: phase, wobble: listening ? Self.listeningWobble : Self.calmWobble)
        let axis = Self.flow(phase)
        let fill = LinearGradient(colors: Self.flowColors, startPoint: axis.start, endPoint: axis.end)
        return ZStack {
            // The glow: the same drop, blurred and set a little lower.
            shape.fill(fill)
                .scaleEffect(0.9)
                .blur(radius: size * 0.16)
                .opacity(listening ? 0.8 : 0.62)
                .offset(y: size * 0.06)
            shape.fill(fill)
                // A soft highlight toward the light, and a faint shade at the rim.
                .overlay(shape.fill(RadialGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0)],
                                                   center: UnitPoint(x: 0.34, y: 0.26),
                                                   startRadius: 0, endRadius: size * 0.3)))
                .overlay(shape.fill(RadialGradient(colors: [Color.clear, Color.black.opacity(0.16)],
                                                   center: .center,
                                                   startRadius: size * 0.28, endRadius: size * 0.52)))
        }
        .scaleEffect(Self.breath(phase))
    }
}

/// The orb as the empty state shows it: it quickens while the new question is dictated.
struct AskEmptyStateOrb: View {
    @ObservedObject var voice: AskVoiceInput

    static let contextID = "chat:new"

    static func listening(phase: AskVoiceInput.Phase, context: String?) -> Bool {
        phase == .listening && context == contextID
    }

    var body: some View {
        AskConversationOrb(listening: Self.listening(phase: voice.phase, context: voice.context))
    }
}

/// A closed blob: a circle whose radius is nudged by three slow sine waves.
/// Each wave turns a whole number of times per loop, so phase 0 and 1 match.
struct AskFluidDropShape: Shape {
    var phase: Double
    var wobble: Double = AskConversationOrb.calmWobble

    static let samples = 48

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    /// The radius at `angle` as a multiple of the base radius.
    static func radiusScale(angle: Double, phase: Double, wobble: Double) -> Double {
        let turn = 2 * .pi * phase
        return 1 + wobble * (0.55 * sin(2 * angle + turn)
            + 0.3 * sin(3 * angle - 2 * turn + 1.3)
            + 0.15 * sin(5 * angle + 3 * turn + 0.4))
    }

    func points(in rect: CGRect) -> [CGPoint] {
        // The base radius leaves room for the widest bulge inside `rect`.
        let radius = min(rect.width, rect.height) / 2 / (1 + wobble)
        return (0 ..< Self.samples).map { index in
            let angle = 2 * .pi * Double(index) / Double(Self.samples)
            let distance = radius * Self.radiusScale(angle: angle, phase: phase, wobble: wobble)
            return CGPoint(x: rect.midX + distance * cos(angle), y: rect.midY + distance * sin(angle))
        }
    }

    /// A closed Catmull-Rom spline through the samples, drawn as cubic curves.
    func path(in rect: CGRect) -> Path {
        let points = points(in: rect)
        let count = points.count
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 0 ..< count {
            let p0 = points[(index + count - 1) % count], p1 = points[index]
            let p2 = points[(index + 1) % count], p3 = points[(index + 2) % count]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}
