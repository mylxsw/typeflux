import SwiftUI

/// The Mac Ask colour drop, with the same outline and eight-second palette flow.
/// Mobile has no recording state; Reduce Motion holds a gently irregular frame.
struct ChatOrb: View {
    var size: CGFloat = 88
    /// Static previews can choose a frame without changing system accessibility settings.
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var appeared = false
    @State private var clock = ChatOrbClock()

    static let period: TimeInterval = 8
    static let stillPhase = 0.15
    nonisolated static let wobble = 0.07
    static let cycleLength = 2.4
    static let colors: [Color] = [
        Color(red: 0.18, green: 0.42, blue: 1),
        Color(red: 0.55, green: 0.36, blue: 0.96),
        Color(red: 1, green: 0.30, blue: 0.55),
        Color(red: 1, green: 0.70, blue: 0.28),
        Color(red: 0.18, green: 0.90, blue: 0.84),
        Color(red: 0.18, green: 0.42, blue: 1)
    ]
    static let flowColors = Array(colors.dropLast()) + colors

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    static func breath(_ phase: Double) -> CGFloat {
        CGFloat(1 + 0.0175 * (1 - cos(4 * .pi * phase)))
    }

    static func flow(_ phase: Double) -> (start: UnitPoint, end: UnitPoint) {
        let angle = .pi / 6 + .pi / 12 * sin(2 * .pi * phase)
        let axisX = cos(angle), axisY = sin(angle)
        let offset = cycleLength * (0.5 + phase)
        let startX = 0.5 - axisX * offset, startY = 0.5 - axisY * offset
        return (UnitPoint(x: startX, y: startY),
                UnitPoint(x: startX + axisX * 2 * cycleLength, y: startY + axisY * 2 * cycleLength))
    }

    var body: some View {
        Group {
            if reduceMotion {
                drop(phase: Self.stillPhase)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    drop(phase: clock.advance(to: context.date))
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
            }
        }
        .accessibilityHidden(true)
    }

    func drop(phase: Double) -> some View {
        let shape = ChatFluidDropShape(phase: phase)
        let axis = Self.flow(phase)
        let fill = LinearGradient(colors: Self.flowColors, startPoint: axis.start, endPoint: axis.end)
        return ZStack {
            shape.fill(fill)
                .scaleEffect(0.9)
                .blur(radius: size * 0.16)
                .opacity(0.62)
                .offset(y: size * 0.06)
            shape.fill(fill)
                .overlay(shape.fill(RadialGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0)],
                    center: UnitPoint(x: 0.34, y: 0.26), startRadius: 0, endRadius: size * 0.3
                )))
                .overlay(shape.fill(RadialGradient(
                    colors: [.clear, .black.opacity(0.16)], center: .center,
                    startRadius: size * 0.28, endRadius: size * 0.52
                )))
        }
        .scaleEffect(Self.breath(phase))
    }
}

/// Integrates visible frame time so returning from the background cannot jump.
final class ChatOrbClock {
    private(set) var phase: Double = 0
    private var last: Date?

    func advance(to date: Date) -> Double {
        let elapsed = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 0.1)
        last = date
        phase = (phase + elapsed / ChatOrb.period).truncatingRemainder(dividingBy: 1)
        return phase
    }
}

/// SwiftUI may build paths away from the main actor; this geometry owns no UI state.
nonisolated struct ChatFluidDropShape: Shape {
    var phase: Double
    static let samples = 48

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    static func radiusScale(angle: Double, phase: Double) -> Double {
        let turn = 2 * .pi * phase
        return 1 + ChatOrb.wobble * (0.55 * sin(2 * angle + turn)
            + 0.3 * sin(3 * angle - 2 * turn + 1.3)
            + 0.15 * sin(5 * angle + 3 * turn + 0.4))
    }

    func points(in rect: CGRect) -> [CGPoint] {
        let radius = min(rect.width, rect.height) / 2 / (1 + ChatOrb.wobble)
        return (0 ..< Self.samples).map { index in
            let angle = 2 * .pi * Double(index) / Double(Self.samples)
            let distance = radius * Self.radiusScale(angle: angle, phase: phase)
            return CGPoint(x: rect.midX + distance * cos(angle), y: rect.midY + distance * sin(angle))
        }
    }

    func path(in rect: CGRect) -> Path {
        let points = points(in: rect)
        let count = points.count
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 0 ..< count {
            let previous = points[(index + count - 1) % count], current = points[index]
            let next = points[(index + 1) % count], following = points[(index + 2) % count]
            path.addCurve(to: next,
                          control1: CGPoint(x: current.x + (next.x - previous.x) / 6,
                                            y: current.y + (next.y - previous.y) / 6),
                          control2: CGPoint(x: next.x - (following.x - current.x) / 6,
                                            y: next.y - (following.y - current.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}
