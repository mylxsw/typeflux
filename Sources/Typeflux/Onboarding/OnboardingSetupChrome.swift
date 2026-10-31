import SwiftUI

/// Opaque, scoped colors keep setup readable regardless of the application's material style.
struct OnboardingSetupPalette {
    let isDark: Bool
    var background: Color {
        isDark ? Color(red: 0.075, green: 0.083, blue: 0.096) : Color(white: 0.985)
    }

    var rail: Color {
        isDark ? Color(red: 0.095, green: 0.106, blue: 0.122) : Color(white: 0.955)
    }

    var surface: Color {
        isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }

    var primary: Color {
        isDark ? Color(white: 0.96) : Color(white: 0.10)
    }

    var secondary: Color {
        isDark ? Color(white: 0.73) : Color(white: 0.38)
    }

    var muted: Color {
        isDark ? Color(white: 0.57) : Color(white: 0.44)
    }

    var separator: Color {
        primary.opacity(isDark ? 0.13 : 0.12)
    }

    var accent: Color {
        isDark ? Color(red: 0.08, green: 0.63, blue: 1) : Color(red: 0, green: 0.36, blue: 0.80)
    }
}

struct OnboardingSetupRail: View {
    let stage: String
    let deferredStages: Set<String>
    let palette: OnboardingSetupPalette
    private let stages = ["services", "models", "permissions", "practice"]

    private var currentIndex: Int {
        stages.firstIndex(of: stage) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: HelpAppIcon.image).resizable().interpolation(.high).frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("Typeflux").font(.studioBody(15, weight: .semibold)).foregroundStyle(palette.primary)
            }
            .padding(.bottom, 38)
            Text(L("setup.rail.title")).font(.studioBody(11.5)).foregroundStyle(palette.secondary)
                .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stages.indices, id: \.self) { index in
                    stageRow(index)
                    if index < stages.count - 1 {
                        Rectangle().fill(palette.separator).frame(width: 1, height: 26).padding(.leading, 8)
                            .accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 20)
            Rectangle().fill(palette.separator).frame(height: 1).padding(.bottom, 18)
            Text(L("setup.rail.later")).font(.studioBody(11.5)).foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 30)
        .padding(.top, 58)
        .padding(.bottom, 32)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(palette.rail)
        .accessibilityElement(children: .contain)
    }

    private func stageRow(_ index: Int) -> some View {
        let isCurrent = index == currentIndex
        let isPast = index < currentIndex
        let isDeferred = isPast && deferredStages.contains(stages[index])
        let title = L(index == stages.count - 1 ? "setup.stage.complete" : "setup.stage.\(stages[index])")
        return HStack(spacing: 12) {
            Image(systemName: isCurrent ? "circle.fill" : isDeferred ? "minus.circle"
                : isPast ? "checkmark.circle" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isCurrent ? palette.accent : palette.muted)
                .frame(width: 18, height: 18).accessibilityHidden(true)
            Text(title).font(.studioBody(12.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? palette.primary : palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isCurrent ? L("setup.rail.current") : isDeferred ? L("setup.rail.skipped")
            : isPast ? L("setup.rail.completed") : "")
    }
}

/// The setup field uses the same native menu bridge as Settings, with the reference's inset field geometry.
struct OnboardingSpeechServicePicker: View {
    let providers: [STTProvider]
    @Binding var selection: STTProvider
    let palette: OnboardingSetupPalette
    @State private var hovering = false

    var body: some View {
        ZStack {
            HStack {
                Text(selection.displayName).font(.studioBody(StudioTheme.Typography.body))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
            .foregroundStyle(palette.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(palette.primary.opacity(hovering ? 0.12 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.separator, lineWidth: 1))
            .accessibilityHidden(true).allowsHitTesting(false)
            TFNativeMenuControl(
                entries: providers.enumerated().map { index, provider in
                    TFNativeMenuEntry(kind: .item(tag: index), title: provider.displayName,
                                      isSelected: provider == selection)
                },
                pullsDown: false, accessibilityTitle: L("setup.speech.serviceLabel"),
                accessibilityValue: selection.displayName, enabled: true
            ) { index in
                guard providers.indices.contains(index) else { return }
                selection = providers[index]
            }
        }
        .frame(height: 34)
        .onHover { hovering = $0 }
    }
}

extension OnboardingView {
    var setupPalette: OnboardingSetupPalette {
        OnboardingSetupPalette(isDark: colorScheme == .dark)
    }

    var usesSetupRail: Bool {
        switch viewModel.currentStep {
        case .services, .cloud, .stt, .llm, .permissions, .finish: true
        default: false
        }
    }

    var deferredSetupStages: Set<String> {
        var stages = Set<String>()
        if viewModel.speechSkipped || viewModel.aiSkipped { stages.insert("models") }
        if viewModel.settingsStore.onboardingPermissionsDeferred { stages.insert("permissions") }
        return stages
    }

    var setupFooter: some View {
        HStack(spacing: 20) {
            StudioButton(title: L("onboarding.v2.action.back"), systemImage: nil, variant: .ghost) {
                viewModel.goBack()
            }
            Spacer(minLength: 8)
            if viewModel.currentStep == .permissions {
                if !viewModel.canAdvance {
                    StudioButton(title: L("setup.action.skip"), systemImage: nil, variant: .ghost) {
                        viewModel.skipPermissions()
                    }
                }
                setupAdvanceButton(L("onboarding.v2.action.continue"), disabled: !viewModel.canAdvance) {
                    viewModel.advance()
                }
            } else if viewModel.currentStep == .finish {
                setupAdvanceButton(L("onboarding.v2.action.finish")) { viewModel.advance() }
            } else {
                if viewModel.currentStep != .services {
                    StudioButton(title: L("setup.action.skip"), systemImage: nil, variant: .ghost) {
                        viewModel.requestSetupSkip()
                    }
                }
                setupAdvanceButton(viewModel.setupPrimaryTitle, disabled: viewModel.isSetupActionRunning,
                                   loading: viewModel.isSetupActionRunning) { viewModel.performSetupAction() }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 28)
        .overlay(alignment: .top) { Rectangle().fill(setupPalette.separator).frame(height: 1) }
    }

    private func setupAdvanceButton(_ title: String, disabled: Bool = false, loading: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        StudioButton(title: title, systemImage: nil, variant: .primary,
                     isDisabled: disabled, isLoading: loading, action: action)
            .keyboardShortcut(.defaultAction)
    }
}
