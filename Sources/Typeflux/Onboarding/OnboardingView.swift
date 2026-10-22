import AppKit
import Combine
import SwiftUI

/// First-run setup window: welcome, permissions, one guide per feature, then every key on one page.
/// Copy stays to one short line per screen; keys, chips and the drawn scenes carry the rest.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroSlide = 0

    private let heroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                Group {
                    switch viewModel.currentStep {
                    case .welcome: welcomeStep
                    case .permissions: permissionsStep
                    case .finish: finishStep
                    case .voice, .launcher, .tools, .ring, .chat:
                        if let feature = viewModel.currentStep.feature { featureStep(feature) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.asymmetric(
                    insertion: .move(edge: viewModel.stepDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .opacity
                ))
                footer
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
        .alert(
            L("onboarding.shortcuts.replacement.appliedAlert.title"),
            isPresented: $viewModel.showShortcutReplacementAppliedAlert
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(shortcutReplacementAppliedMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.refreshGlobeKeyState()
        }
        .onReceive(heroTimer) { _ in
            guard viewModel.currentStep == .welcome, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                heroSlide = (heroSlide + 1) % OnboardingWelcomeHero.Scene.welcome.count
            }
        }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            StudioTheme.windowBackground
            RadialGradient(
                colors: [StudioTheme.accent.opacity(isDarkMode ? 0.12 : 0.07), .clear],
                center: .topTrailing, startRadius: 20, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if viewModel.currentStep != .welcome {
                ForEach(viewModel.visibleSteps.filter { $0 != .welcome }, id: \.self) { step in
                    Capsule()
                        .fill(step == viewModel.currentStep ? secondaryText : borderColor)
                        .frame(width: step == viewModel.currentStep ? 20 : 6, height: 6)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.currentStep)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch viewModel.currentStep {
            case .welcome:
                languageMenu
                Spacer()
                Label(L("onboarding.v2.welcome.duration"), systemImage: "clock")
                    .font(.studioBody(12))
                    .foregroundStyle(tertiaryText)
                StudioButton(title: L("onboarding.v2.action.start"), systemImage: nil, variant: .primary) {
                    viewModel.advance()
                }
            case .permissions:
                backButton
                Spacer()
                if !viewModel.allRequiredPermissionsGranted {
                    StudioButton(title: L("onboarding.v2.action.later"), systemImage: nil, variant: .ghost) {
                        viewModel.skipPermissions()
                    }
                }
                StudioButton(
                    title: L("onboarding.v2.action.continue"), systemImage: nil, variant: .primary,
                    isDisabled: !viewModel.canAdvance
                ) {
                    viewModel.advance()
                }
            case .voice, .launcher, .tools, .ring, .chat:
                backButton
                Spacer()
                if let index = viewModel.featureSteps.firstIndex(of: viewModel.currentStep) {
                    Text("\(index + 1) / \(viewModel.featureSteps.count)")
                        .font(.studioBody(12))
                        .foregroundStyle(tertiaryText)
                }
                StudioButton(title: L("onboarding.v2.action.next"), systemImage: nil, variant: .primary) {
                    viewModel.advance()
                }
            case .finish:
                backButton
                Spacer()
                StudioButton(title: L("onboarding.v2.action.finish"), systemImage: nil, variant: .primary) {
                    viewModel.advance()
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
    }

    private var backButton: some View {
        StudioButton(title: L("onboarding.v2.action.back"), systemImage: nil, variant: .ghost) {
            viewModel.goBack()
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Button(language.displayName) { viewModel.setLanguage(language) }
            }
        } label: {
            Label(viewModel.appLanguage.displayName, systemImage: "globe")
                .font(.studioBody(12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(tertiaryText)
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
                    ForEach(Array(viewModel.shortcuts(for: feature).enumerated()), id: \.element.id) { index, shortcut in
                        if index > 0 { Divider().opacity(0.6) }
                        shortcutRow(shortcut)
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderColor, lineWidth: 1))
                .padding(.top, 24)
                if feature == .voice {
                    voicePractice
                        .padding(.top, 14)
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
                    Text(L("onboarding.v2.voice.practice.placeholder", HotkeyFormat.display(viewModel.activationHotkey)))
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

    // MARK: - Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle(L("onboarding.v2.finish.title"), subtitle: L("onboarding.v2.finish.subtitle"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(OnboardingFeature.allCases) { feature in
                    finishCard(feature)
                }
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 56)
        .padding(.top, 4)
    }

    private func finishCard(_ feature: OnboardingFeature) -> some View {
        let shortcut = viewModel.shortcuts(for: feature).first
        return HStack(spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(primaryText)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(mutedFill))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.studioBody(13.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(shortcut?.title ?? "")
                    .font(.studioBody(12))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let keys = shortcut?.keys, !keys.isEmpty {
                OnboardingKeycaps(keys: keys)
            } else {
                Text(L("onboarding.v2.shortcut.notSet"))
                    .font(.studioBody(12))
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderColor, lineWidth: 1))
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle(
                viewModel.allRequiredPermissionsGranted
                    ? L("onboarding.v2.permissions.title.ready")
                    : L("onboarding.v2.permissions.title.missing", viewModel.missingPermissionCount),
                subtitle: L("onboarding.v2.permissions.subtitle")
            )
            VStack(spacing: 10) {
                ForEach(viewModel.requiredPermissions) { snapshot in
                    permissionRow(snapshot)
                }
                if viewModel.needsGlobeKeySetup {
                    globeKeyRow
                }
            }
            .padding(.top, 20)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text(L("onboarding.v2.permissions.later"))
                chip(L("onboarding.v2.later.screen"), symbol: "rectangle.dashed")
                chip(L("onboarding.v2.later.ai"), symbol: "sparkles")
            }
            .font(.studioBody(12))
            .foregroundStyle(tertiaryText)
            .padding(.top, 18)
        }
        .padding(.horizontal, 56)
        .padding(.top, 4)
    }

    private func permissionRow(_ snapshot: PrivacyGuard.PermissionSnapshot) -> some View {
        let isRequesting = viewModel.requestingPermissions.contains(snapshot.id)
        return HStack(spacing: 16) {
            Image(systemName: permissionSymbol(snapshot.id))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(primaryText)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(mutedFill))
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.studioBody(14.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(L("onboarding.v2.permission.\(snapshot.id.rawValue).detail"))
                    .font(.studioBody(12.5))
                    .foregroundStyle(secondaryText)
                HStack(spacing: 5) {
                    ForEach(OnboardingFeature.features(using: snapshot.id)) { feature in
                        chip(feature.title, symbol: nil)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            if snapshot.isGranted {
                Label(snapshot.badgeText, systemImage: "checkmark.circle.fill")
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(StudioTheme.success)
            } else {
                StudioButton(
                    title: snapshot.actionTitle, systemImage: nil, variant: .secondary,
                    isDisabled: isRequesting, isLoading: isRequesting
                ) {
                    viewModel.requestPermission(snapshot.id)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(snapshot.isGranted ? StudioTheme.success.opacity(0.4) : borderColor, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: snapshot.isGranted)
    }

    /// Only shown when macOS keeps 🌐 for itself: fix it in Settings, or move voice input to a right-hand key.
    private var globeKeyRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(StudioTheme.warning)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.warning.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("onboarding.v2.globe.title"))
                    .font(.studioBody(14.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(viewModel.shortcutReplacementConflict
                    ? L("onboarding.v2.globe.conflict")
                    : L("onboarding.v2.globe.detail"))
                    .font(.studioBody(12.5))
                    .foregroundStyle(viewModel.shortcutReplacementConflict ? StudioTheme.warning : secondaryText)
            }
            Spacer(minLength: 12)
            StudioButton(title: L("onboarding.v2.globe.open"), systemImage: nil, variant: .secondary, isCompact: true) {
                viewModel.openKeyboardSystemSettings()
            }
            .fixedSize()
            Menu {
                Button(L("onboarding.shortcuts.externalKeyboard.useRightCommand")) {
                    viewModel.useExternalKeyboardShortcutReplacement(.rightCommand)
                }
                Button(L("onboarding.shortcuts.externalKeyboard.useRightOption")) {
                    viewModel.useExternalKeyboardShortcutReplacement(.rightOption)
                }
            } label: {
                Text(L("onboarding.v2.globe.useOtherKey"))
                    .font(.studioBody(12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StudioTheme.warning.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(StudioTheme.warning.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Pieces

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.studioDisplay(28, weight: .bold))
                .foregroundStyle(primaryText)
            Text(subtitle)
                .font(.studioBody(14))
                .foregroundStyle(secondaryText)
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

    private func permissionSymbol(_ id: PrivacyGuard.PermissionID) -> String {
        switch id {
        case .microphone: "mic"
        case .speechRecognition: "waveform"
        case .accessibility: "accessibility"
        }
    }

    private var shortcutReplacementAppliedMessage: String {
        guard let replacement = viewModel.externalKeyboardShortcutReplacement else {
            return L("onboarding.shortcuts.replacement.restoredAlert.message")
        }
        let name = L("onboarding.shortcuts.replacement.\(replacement.rawValue)")
        return L("onboarding.shortcuts.replacement.appliedAlert.message", name, name)
    }

    // MARK: - Colors

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
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

/// A row of keycaps, e.g. ⌘ Space.
struct OnboardingKeycaps: View {
    let keys: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.studioBody(11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 21)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.1) : StudioTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : StudioTheme.border, lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
