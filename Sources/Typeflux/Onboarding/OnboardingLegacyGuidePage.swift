import SwiftUI

/// Retained until GUL-642 removes the superseded feature guides.
struct OnboardingLegacyGuidePage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let feature: OnboardingFeature
    @Environment(\.colorScheme) private var colorScheme
    var body: some View { featureStep(feature) }
    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
    // MARK: - Feature guides

    private func featureStep(_ feature: OnboardingFeature) -> some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(mutedFill))
                stepTitle(feature.title, subtitle: feature.caption)
                    .padding(.top, 20)
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.guideShortcuts(for: feature).enumerated()), id: \.element.id) { index, shortcut in
                        if index > 0 { Divider().opacity(0.6) }
                        shortcutRow(shortcut)
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderColor, lineWidth: 1))
                .padding(.top, 24)
                if feature == .launcher,
                   viewModel.permissions.first(where: { $0.id == .accessibility })?.isGranted != true {
                    Text(L("setup.launcher.permissionsHint"))
                        .font(.studioBody(12.5)).foregroundStyle(secondaryText).padding(.top, 14)
                }
                if feature == .voice {
                    if viewModel.allRequiredPermissionsGranted && !viewModel.needsGlobeKeySetup {
                        voicePractice.padding(.top, 14)
                    } else {
                        Text(L("setup.voice.permissionsFirst"))
                            .font(.studioBody(12.5)).foregroundStyle(secondaryText).padding(.top, 14)
                        Button(L("setup.action.permissions")) { viewModel.currentStep = .permissions }
                            .buttonStyle(.link).padding(.top, 6)
                    }
                }
            }
            .frame(width: 380, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)

            OnboardingWelcomeHero(scene: .init(feature), showsCaption: false)
                .padding(.bottom, 6)
        }
        .padding(.leading, 56)
        .padding(.trailing, 24)
    }

    private func shortcutRow(_ shortcut: OnboardingShortcut) -> some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(.studioBody(13))
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if shortcut.keys.isEmpty {
                Text(L("onboarding.v2.shortcut.notSet"))
                    .font(.studioBody(12))
                    .foregroundStyle(tertiaryText)
            } else {
                OnboardingKeycaps(keys: shortcut.keys)
            }
        }
        .frame(height: 44)
    }

    /// Voice input writes into Typeflux's own text views too, so the guide can be tried in place.
    private var voicePractice: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.voicePracticeText)
                    .font(.studioBody(13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if viewModel.voicePracticeText.isEmpty {
                    Text(L("onboarding.v2.voice.practice.placeholder",
                           HotkeyFormat.display(viewModel.activationHotkey)))
                        .font(.studioBody(13))
                        .foregroundStyle(tertiaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(viewModel.didPracticeVoice ? StudioTheme.success.opacity(0.5) : borderColor, lineWidth: 1)
            )
            if viewModel.didPracticeVoice {
                Label(L("onboarding.v2.voice.practice.done"), systemImage: "checkmark.circle.fill")
                    .font(.studioBody(12, weight: .medium))
                    .foregroundStyle(StudioTheme.success)
            }
        }
    }

    private func chip(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            }
            Text(title).lineLimit(1)
        }
        .font(.studioBody(11.5, weight: .medium))
        .foregroundStyle(secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(mutedFill))
    }

    private var isDarkMode: Bool { colorScheme == .dark }
    private var primaryText: Color { StudioTheme.textPrimary }
    private var secondaryText: Color { StudioTheme.textSecondary }
    private var tertiaryText: Color { StudioTheme.textTertiary }
    private var cardFill: Color { isDarkMode ? Color.white.opacity(0.045) : StudioTheme.surface }
    private var mutedFill: Color { isDarkMode ? Color.white.opacity(0.07) : StudioTheme.surfaceMuted }
    private var borderColor: Color { isDarkMode ? Color.white.opacity(0.09) : StudioTheme.border }
}
