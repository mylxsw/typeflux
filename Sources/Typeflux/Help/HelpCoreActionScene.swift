import SwiftUI

/// The stage beside the core actions: the action's own small scene on its tinted glow, as on the
/// welcome screen, playing in a loop. Practice replaces the animation with the real thing.
struct HelpCoreActionScene: View {
    @ObservedObject var model: HelpGuideModel
    var action: HelpCoreAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.usesGlass ? 18 : style.help.blockCorner, style: .continuous)
    }

    private var practicing: Bool { model.practicingAction == action }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            shape.fill(colorScheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.09)
                : Color(red: 0.88, green: 0.9, blue: 0.94))
            RadialGradient(colors: [action.tint.opacity(0.36), .clear], center: UnitPoint(x: 0.3, y: 0.05),
                           startRadius: 10, endRadius: 420)
                .clipShape(shape)
            Group {
                if practicing {
                    practice
                } else {
                    scene.accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, practicing ? 8 : 24)
            .padding(.bottom, practicing ? 8 : 40)
            .id(action)
            // Practice says what to do itself and needs the room.
            if !practicing {
                Text(action.caption)
                    .font(.studioBody(12.5))
                    .foregroundStyle(colorScheme == .dark ? Color.white : StudioTheme.textPrimary)
                    .padding(16)
            }
        }
        .overlay(alignment: .topTrailing) { usageTag.padding(14) }
        .overlay(shape.stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
    }

    private var usageTag: some View {
        let count = model.usageCount(action)
        return HStack(spacing: 6) {
            Circle().fill(count > 0 ? StudioTheme.success : action.tint).frame(width: 7, height: 7)
            Text(count > 0 ? L("help.action.used", count) : L("help.action.untried"))
                .font(.system(size: 11))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.85) : StudioTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.7)))
    }

    @ViewBuilder private var scene: some View {
        switch action {
        case .voice: HelpVoiceScene()
        case .launcher: HelpLauncherScene()
        case .ring: HelpRingScene()
        case .chat: HelpChatScene()
        }
    }

    @ViewBuilder private var practice: some View {
        switch action {
        case .voice: HelpVoicePractice(keys: model.catalog.voiceKeys) { model.reloadUsage() }
        case .ring: HelpRingPractice(configuration: model.sources.settings.ringConfiguration) {
                model.recordPractice(.ring)
            }
        case .launcher, .chat: EmptyView()
        }
    }
}

/// A window in a scene, like the document on the welcome screen.
struct HelpSceneDocument<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Circle().fill(StudioTheme.textTertiary.opacity(0.35)).frame(width: 9, height: 9)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(StudioTheme.surface))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
    }
}

/// Spoken words arriving in a document, with the capsule that shows them live.
struct HelpVoiceScene: View {
    var body: some View {
        HelpLoop(period: 7, stillPhase: 0.9) { phase in
            VStack(spacing: 24) {
                HelpSceneDocument {
                    HStack(alignment: .lastTextBaseline, spacing: 1) {
                        // The full text sits underneath so the document keeps its size while typing.
                        Text(L("onboarding.v2.hero.voice.text")).hidden().overlay(alignment: .topLeading) {
                            Text(HelpSceneTimeline.revealed(L("onboarding.v2.hero.voice.text"), phase: phase))
                        }
                    }
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
        }
    }
}

/// A keyword and a word being typed, with the result arriving under them.
struct HelpLauncherScene: View {
    private let word = "serendipity"

    var body: some View {
        HelpLoop(period: 6, stillPhase: 0.9) { phase in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").opacity(0.5)
                    Text("fy")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.6, green: 0.8, blue: 1))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.25)))
                    Text(HelpSceneTimeline.revealed(word, phase: phase, end: 0.45))
                        .font(.studioBody(17))
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("↩").opacity(0.5)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.1)))
                .padding(6)
                .opacity(phase > 0.5 ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: phase > 0.5)
            }
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.17).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
            .frame(maxWidth: 440)
        }
    }
}

/// The ring with the pointer moving from slice to slice.
struct HelpRingScene: View {
    private static let labels: [(String, String)] = [
        ("mic", "onboarding.v2.hero.ring.voice"), ("sparkles", "onboarding.v2.hero.ring.ask"),
        ("character.bubble", "onboarding.v2.hero.ring.translate"),
        ("camera.viewfinder", "onboarding.v2.hero.ring.screenshot"),
        ("text.viewfinder", "onboarding.v2.hero.ring.ocr"), ("doc.on.clipboard", "onboarding.v2.hero.ring.clipboard")
    ]

    var body: some View {
        HelpLoop(period: 6, stillPhase: 0.1) { phase in
            OnboardingRingPreview(labels: Self.labels,
                                  highlighted: HelpSceneTimeline.slice(phase: phase, count: Self.labels.count))
                .frame(width: 250, height: 250)
        }
    }
}

/// A question about the screen, the step that read it, and the answer being written.
struct HelpChatScene: View {
    var body: some View {
        HelpLoop(period: 7, stillPhase: 0.9) { phase in
            HelpSceneDocument {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer(minLength: 0)
                        Text(L("onboarding.v2.hero.chat.question"))
                            .font(.studioBody(13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 14).fill(StudioTheme.textPrimary.opacity(0.08)))
                    }
                    Label(L("onboarding.v2.hero.chat.step"), systemImage: "checkmark.circle")
                        .font(.studioBody(12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .opacity(phase > 0.15 ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: phase > 0.15)
                    Text(L("onboarding.v2.hero.chat.answer")).hidden().overlay(alignment: .topLeading) {
                        Text(HelpSceneTimeline.revealed(L("onboarding.v2.hero.chat.answer"), phase: phase,
                                                        start: 0.25, end: 0.7))
                    }
                    .font(.studioBody(13))
                    .lineSpacing(4)
                }
                .foregroundStyle(StudioTheme.textPrimary)
            }
        }
    }
}

/// A real text area: holding the voice key writes into it, as it would in any other app.
struct HelpVoicePractice: View {
    var keys: [String]?
    var onText: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            HelpSceneDocument {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("help.action.voice.practice.placeholder"))
                            .font(.studioBody(14))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.studioBody(14))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .accessibilityLabel(L("help.action.voice.practice.placeholder"))
                }
                .frame(height: 96)
            }
            HelpKeycaps(keys: keys)
        }
        .onAppear { focused = true }
        .onChange(of: text) { _ in onText() }
    }
}

/// The live ring on the user's own actions. Choosing a slice only names it; nothing runs.
struct HelpRingPractice: View {
    var configuration: RingConfiguration
    var onSelect: () -> Void
    @State private var pointed: String?
    @State private var selected: String?

    var body: some View {
        GeometryReader { proxy in
            let scale = Self.scale(for: proxy.size)
            VStack(spacing: 6) {
                if configuration.actions.isEmpty {
                    Text(OnboardingStrings.text("ring.empty", table: "OnboardingTry"))
                        .font(.studioBody(13))
                        .foregroundStyle(StudioTheme.textSecondary)
                } else {
                    OnboardingNativeRingPreview(configuration: configuration, scale: scale, onHover: { id in
                        pointed = title(id)
                    }, onSelect: { id in
                        selected = title(id)
                        onSelect()
                    })
                    .id(scale)
                    .accessibilityRepresentation {
                        VStack {
                            ForEach(configuration.actions) { action in
                                Button(action.title) {
                                    selected = action.title
                                    onSelect()
                                }
                            }
                        }
                    }
                    Text(selected.map { L("help.action.ring.practice.selected", $0) } ?? pointed
                        ?? L("help.action.ring.practice.hint"))
                        .font(.studioBody(12, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The largest size of the live ring that fits with its hint; its labels stand outside it.
    static func scale(for size: CGSize) -> CGFloat {
        if size.width >= 368, size.height >= 344 { return 0.8 }
        return size.width >= 322 && size.height >= 304 ? 0.7 : 0.6
    }

    private func title(_ id: String) -> String? {
        configuration.actions.first { $0.id.uuidString == id }?.title
    }
}
