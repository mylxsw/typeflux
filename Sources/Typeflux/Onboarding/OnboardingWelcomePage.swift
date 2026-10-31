import Combine
import SwiftUI

struct OnboardingWelcomePage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var heroSlide = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    var body: some View {
        welcomeStep.onReceive(heroTimer) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                heroSlide = (heroSlide + 1) % OnboardingWelcomeHero.Scene.welcome.count
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: HelpAppIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
                Text(L("onboarding.v2.welcome.title"))
                    .font(.studioDisplay(34, weight: .bold))
                    .foregroundStyle(primaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                Text(L("onboarding.v2.welcome.lead"))
                    .font(.studioBody(14))
                    .foregroundStyle(secondaryText)
                    .padding(.top, 12)
                VStack(spacing: 2) {
                    ForEach(OnboardingWelcomeHero.Scene.welcome, id: \.self) { scene in
                        verbRow(scene)
                    }
                }
                .padding(.top, 24)
            }
            .frame(width: 350, alignment: .leading)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 20)

            OnboardingWelcomeHero(scene: OnboardingWelcomeHero.Scene.welcome[heroSlide])
                .padding(.bottom, 6)
        }
        .padding(.leading, 56)
        .padding(.trailing, 24)
    }

    private func verbRow(_ scene: OnboardingWelcomeHero.Scene) -> some View {
        let isOn = OnboardingWelcomeHero.Scene.welcome[heroSlide] == scene
        return Button {
            withAnimation(.easeInOut(duration: 0.4)) {
                heroSlide = OnboardingWelcomeHero.Scene.welcome.firstIndex(of: scene) ?? 0
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(scene.verb)
                    .font(.studioBody(13.5, weight: .semibold))
                Text(scene.featureName)
                    .font(.studioBody(13.5))
                Spacer(minLength: 8)
                OnboardingKeycaps(keys: keys(for: scene))
                    .opacity(isOn ? 1 : 0.55)
            }
            .foregroundStyle(isOn ? primaryText : tertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isOn ? cardFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func keys(for scene: OnboardingWelcomeHero.Scene) -> [String] {
        switch scene {
        case .voice: HotkeyFormat.components(viewModel.activationHotkey)
        case .launcher, .tools: viewModel.launcherHotkey.map(HotkeyFormat.components) ?? []
        case .ring: viewModel.ringHotkey.map(HotkeyFormat.components) ?? []
        case .chat: ["⌘", "↩"]
        }
    }

    private var isDarkMode: Bool { colorScheme == .dark }
    private var primaryText: Color { StudioTheme.textPrimary }
    private var secondaryText: Color { StudioTheme.textSecondary }
    private var tertiaryText: Color { StudioTheme.textTertiary }
    private var cardFill: Color { isDarkMode ? Color.white.opacity(0.045) : StudioTheme.surface }
    private var mutedFill: Color { isDarkMode ? Color.white.opacity(0.07) : StudioTheme.surfaceMuted }
    private var borderColor: Color { isDarkMode ? Color.white.opacity(0.09) : StudioTheme.border }
}
