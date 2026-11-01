import SwiftUI

/// One small, real-looking scene per feature: the welcome screen rotates through the four verbs
/// (speak, find, swipe, ask) and each guide screen shows its own. Scenes are drawn, not
/// screenshots, so they follow the theme.
struct OnboardingWelcomeHero: View {
    enum Scene: CaseIterable, Hashable {
        case voice
        case launcher
        case tools
        case ring
        case chat

        /// The verbs the welcome screen lists and rotates through.
        static let welcome: [Scene] = [.voice, .launcher, .ring, .chat]

        init(_ feature: OnboardingFeature) {
            switch feature {
            case .voice: self = .voice
            case .launcher: self = .launcher
            case .tools: self = .tools
            case .ring: self = .ring
            case .chat: self = .chat
            }
        }

        var symbol: String {
            switch self {
            case .voice: "mic"
            case .launcher: "magnifyingglass"
            case .tools: "square.grid.2x2"
            case .ring: "circle.circle"
            case .chat: "bubble.left.and.bubble.right"
            }
        }

        var key: String {
            switch self {
            case .voice: "voice"
            case .launcher: "launcher"
            case .tools: "tools"
            case .ring: "ring"
            case .chat: "chat"
            }
        }

        /// Only the welcome scenes have a verb.
        var verb: String { L("onboarding.v2.verb.\(key)") }
        var featureName: String { L("onboarding.v2.verb.\(key).detail") }
        var caption: String { L("onboarding.v2.hero.\(key)") }

        var tint: Color {
            switch self {
            case .voice: Color(red: 1, green: 0.44, blue: 0.32)
            case .launcher: Color(red: 0.27, green: 0.55, blue: 1)
            case .tools: Color(red: 0.2, green: 0.75, blue: 0.6)
            case .ring: Color(red: 0.67, green: 0.39, blue: 1)
            case .chat: Color(red: 1, green: 0.67, blue: 0.24)
            }
        }
    }

    let scene: Scene
    /// Guide screens already say the same thing in their title.
    var showsCaption = true
    /// Redraws the scene text when the language changes mid-setup.
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.09) : Color(red: 0.88, green: 0.9, blue: 0.94))
            RadialGradient(colors: [scene.tint.opacity(0.36), .clear], center: UnitPoint(x: 0.3, y: 0.05),
                           startRadius: 10, endRadius: 420)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Group {
                switch scene {
                case .voice: voiceScene
                case .launcher: launcherScene
                case .tools: toolsScene
                case .ring: ringScene
                case .chat: chatScene
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(scene)
            .transition(.opacity)
            if showsCaption {
                Text(scene.caption)
                    .font(.studioBody(12.5))
                    .foregroundStyle(colorScheme == .dark ? Color.white : StudioTheme.textPrimary)
                    .padding(20)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scene.caption)
    }

    // MARK: Scenes

    private var voiceScene: some View {
        VStack(spacing: 28) {
            document {
                Text(L("onboarding.v2.hero.voice.text"))
                    .font(.studioBody(14))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                OnboardingWaveform()
                Text(L("onboarding.v2.hero.voice.live"))
                    .font(.studioBody(12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(Capsule().fill(Color.black.opacity(0.88)))
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 30)
    }

    private var launcherScene: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").opacity(0.5)
                Text("fy")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.6, green: 0.8, blue: 1))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.25)))
                Text("serendipity")
                    .font(.studioBody(17))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 10) {
                Image(systemName: "character.bubble")
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
                Text(L("onboarding.v2.hero.launcher.result"))
                    .font(.studioBody(14))
                Spacer()
                Text("↩").opacity(0.5)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.1)))
            .padding(6)
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.17).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
        .padding(.horizontal, 30)
        .padding(.bottom, 40)
    }

    /// A word translated in place, with a GIF recording running below.
    private var toolsScene: some View {
        VStack(alignment: .leading, spacing: 22) {
            document {
                VStack(alignment: .leading, spacing: 10) {
                    (Text("We met by pure ") + Text("serendipity").foregroundColor(StudioTheme.accent) + Text("."))
                        .font(.studioBody(14))
                        .foregroundStyle(StudioTheme.textPrimary)
                    HStack(spacing: 8) {
                        Image(systemName: "character.bubble")
                        Text(L("onboarding.v2.hero.launcher.result"))
                            .lineLimit(1)
                    }
                    .font(.studioBody(12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(StudioTheme.textPrimary.opacity(0.06)))
                }
            }
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("0:07")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                Text("GIF")
                    .font(.studioBody(11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 40)
    }

    private var ringScene: some View {
        OnboardingRingPreview(
            labels: [("mic", "onboarding.v2.hero.ring.voice"), ("sparkles", "onboarding.v2.hero.ring.ask"),
                     ("character.bubble", "onboarding.v2.hero.ring.translate"), ("camera.viewfinder", "onboarding.v2.hero.ring.screenshot"),
                     ("text.viewfinder", "onboarding.v2.hero.ring.ocr"), ("doc.on.clipboard", "onboarding.v2.hero.ring.clipboard")],
            highlighted: 2
        )
        .frame(width: 280, height: 280)
        .padding(.bottom, 30)
    }

    private var chatScene: some View {
        document {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Text(L("onboarding.v2.hero.chat.question"))
                        .font(.studioBody(13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 14).fill(StudioTheme.textPrimary.opacity(0.08)))
                }
                Label(L("onboarding.v2.hero.chat.step"), systemImage: "checkmark.circle")
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(L("onboarding.v2.hero.chat.answer"))
                    .font(.studioBody(13))
                    .lineSpacing(4)
            }
            .foregroundStyle(StudioTheme.textPrimary)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 40)
    }

    private func document(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { _ in Circle().fill(StudioTheme.textTertiary.opacity(0.35)).frame(width: 9, height: 9) }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(StudioTheme.surface))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
    }
}

/// Animated level bars for the voice capsule. Holds still with Reduce Motion.
struct OnboardingWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heights: [CGFloat] = [0.35, 0.7, 1, 0.55, 0.85, 0.4, 0.95, 0.6, 0.3, 0.75, 0.9, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(heights.indices, id: \.self) { index in
                    let phase = CGFloat(reduceMotion ? 0 : sin(elapsed * 6 + Double(index) * 0.9) * 0.35)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: max(4, 16 * min(1, max(0.2, heights[index] + phase))))
                }
            }
            .frame(height: 18)
        }
    }
}

/// A static ring with one highlighted slice, matching the real ring's layout.
struct OnboardingRingPreview: View {
    /// (SF Symbol, localization key) per slice, clockwise from the top.
    let labels: [(String, String)]
    let highlighted: Int

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let outer = size / 2
            let inner = outer * 0.37
            ZStack {
                ForEach(labels.indices, id: \.self) { index in
                    slice(index: index, center: center, outer: outer, inner: inner)
                        .fill(index == highlighted ? StudioTheme.accent : Color(white: 0.17).opacity(0.92))
                    slice(index: index, center: center, outer: outer, inner: inner)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    let theta = angle(for: Double(index))
                    let radius = (outer + inner) / 2
                    VStack(spacing: 3) {
                        Image(systemName: labels[index].0).font(.system(size: 15))
                        Text(L(labels[index].1)).font(.studioBody(10.5))
                    }
                    .foregroundStyle(.white)
                    .position(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
                }
                Circle()
                    .fill(Color(white: 0.11))
                    .frame(width: inner * 2 - 6, height: inner * 2 - 6)
                    .position(center)
                Text("Typeflux")
                    .font(.studioBody(12, weight: .semibold))
                    .foregroundStyle(.white)
                    .position(center)
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        }
    }

    private func angle(for index: Double) -> Double {
        -Double.pi / 2 + index * 2 * Double.pi / Double(labels.count)
    }

    private func slice(index: Int, center: CGPoint, outer: CGFloat, inner: CGFloat) -> Path {
        let half = Double.pi / Double(labels.count), gap = 0.03
        let start = angle(for: Double(index)) - half + gap, end = angle(for: Double(index)) + half - gap
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: inner + 4, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
