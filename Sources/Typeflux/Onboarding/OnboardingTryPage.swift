import SwiftUI

struct OnboardingTryPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingTryModel
    @FocusState private var voiceFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingEditorialHeader(
                eyebrow: OnboardingStrings.text("eyebrow", table: "OnboardingTry"),
                title: OnboardingStrings.text("title", table: "OnboardingTry"),
                subtitle: nil,
                pill: OnboardingStep.try.pill
            )
            HStack(alignment: .top, spacing: 18) {
                featureList
                    .frame(width: 270)
                practiceCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 6)
    }

    // MARK: - Left Feature List

    private var featureList: some View {
        VStack(spacing: 6) {
            ForEach(OnboardingTryModel.Feature.allCases) { feature in
                featureRow(feature)
            }
        }
    }

    private func featureRow(_ feature: OnboardingTryModel.Feature) -> some View {
        let isSelected = model.selectedFeature == feature
        let isConnected = model.isConnected(feature)
        let keys = model.shortcutKeys(for: feature)

        return Button { model.selectFeature(feature) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                    Image(systemName: feature.iconSymbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
                .frame(width: 32, height: 32)

                Text(featureTitle(feature))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isConnected ? Color.primary : Color.secondary.opacity(0.6))

                Spacer()

                featureAccessory(feature, connected: isConnected, keys: keys)
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.045) : Color.white) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.07) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(featureTitle(feature))
        .accessibilityValue(isConnected ? keys.joined(separator: " ") :
            OnboardingStrings.text("status.notConnected", table: "OnboardingTry"))
    }

    @ViewBuilder
    private func featureAccessory(_ feature: OnboardingTryModel.Feature, connected: Bool, keys: [String]) -> some View {
        if model.isTried(feature) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.188, green: 0.82, blue: 0.345))
        } else if connected, !keys.isEmpty {
            OnboardingKeycaps(keys: keys)
        } else {
            Text(OnboardingStrings.text(connected ? "status.notSet" : "status.notConnected", table: "OnboardingTry"))
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Right Practice Card

    private var practiceCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(heroGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

            VStack(spacing: 18) {
                if !model.isConnected(model.selectedFeature) {
                    notConnectedArea
                } else {
                    switch model.selectedFeature {
                    case .voice:
                        voiceArea
                    case .launcher:
                        launcherArea
                    case .ring:
                        ringArea
                    case .chat:
                        chatArea
                    }
                }
            }
            .padding(model.selectedFeature == .ring ? 12 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var heroGradient: RadialGradient {
        if model.selectedFeature == .ring {
            return RadialGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.14, green: 0.17, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.12)]
                    : [Color(red: 0.93, green: 0.95, blue: 0.98), Color(red: 0.98, green: 0.98, blue: 0.99)],
                center: .topLeading, startRadius: 0, endRadius: 500
            )
        }
        if colorScheme == .dark {
            return RadialGradient(
                colors: [
                    Color(red: 0.231, green: 0.165, blue: 0.4),
                    Color(red: 0.133, green: 0.114, blue: 0.212),
                    Color(red: 0.094, green: 0.09, blue: 0.11)
                ],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadius: 0,
                endRadius: 500
            )
        } else {
            return RadialGradient(
                colors: [
                    Color(red: 0.902, green: 0.867, blue: 0.988),
                    Color(red: 0.941, green: 0.925, blue: 0.98),
                    Color(red: 0.969, green: 0.969, blue: 0.976)
                ],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadius: 0,
                endRadius: 500
            )
        }
    }

    // MARK: - Practice Subviews

    private var notConnectedArea: some View {
        VStack(spacing: 18) {
            Text(OnboardingStrings.text("connect.needed", table: "OnboardingTry",
                                        arguments: [featureTitle(model.selectedFeature)]))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)

            Button { viewModel.returnToRoute() } label: {
                Text(OnboardingStrings.text("connect.button", table: "OnboardingTry"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

extension OnboardingTryPage {
    private var voiceArea: some View {
        VStack(spacing: 18) {
            instructionView(
                prefix: OnboardingStrings.text("voice.instructionPrefix", table: "OnboardingTry"),
                keys: model.shortcutKeys(for: .voice),
                suffix: OnboardingStrings.text("voice.instructionSuffix", table: "OnboardingTry")
            )

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.voicePracticeText)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($voiceFocused)
                    .onAppear { voiceFocused = true }

                if viewModel.voicePracticeText.isEmpty {
                    HStack(spacing: 2) {
                        Text(OnboardingStrings.text("voice.placeholder", table: "OnboardingTry"))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 14)
                    }
                    .padding(.top, 4)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 400)
            .frame(height: 92)
            .background(
                colorScheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color.white,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 14, y: 8)
        }
    }

    private var launcherArea: some View {
        VStack(spacing: 18) {
            instructionView(
                prefix: OnboardingStrings.text("launcher.instructionPrefix", table: "OnboardingTry"),
                keys: model.shortcutKeys(for: .launcher),
                suffix: OnboardingStrings.text("launcher.instructionSuffix", table: "OnboardingTry")
            )

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(OnboardingStrings.text("launcher.query", table: "OnboardingTry"))
                        .font(.system(size: 15))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.5)

                VStack(spacing: 2) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                        Text(OnboardingStrings.text("launcher.resultTitle", table: "OnboardingTry"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(OnboardingStrings.text("launcher.resultAction", table: "OnboardingTry"))
                            .font(.system(size: 11.5))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(OnboardingStrings.text("launcher.resultSearch", table: "OnboardingTry"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                }
                .padding(5)
            }
            .frame(maxWidth: 420)
            .background(
                colorScheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color.white,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 18, y: 10)

            triedButton(for: .launcher)
        }
    }

    private var ringArea: some View {
        OnboardingRingPractice(model: model)
    }

    private var chatArea: some View {
        VStack(spacing: 18) {
            instructionView(
                prefix: OnboardingStrings.text("chat.instructionPrefix", table: "OnboardingTry"),
                keys: ["↩"],
                suffix: ""
            )

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(OnboardingStrings.text("chat.query", table: "OnboardingTry"))
                        .font(.system(size: 15))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.5)

                VStack(spacing: 2) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                        Text(OnboardingStrings.text("chat.result", table: "OnboardingTry"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(5)
            }
            .frame(maxWidth: 420)
            .background(
                colorScheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color.white,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 18, y: 10)

            triedButton(for: .chat)
        }
    }

    private func triedButton(for feature: OnboardingTryModel.Feature) -> some View {
        Button { model.markTried(feature) } label: {
            Text(OnboardingStrings.text("button.tried", table: "OnboardingTry"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func instructionView(prefix: String, keys: [String], suffix: String) -> some View {
        HStack(spacing: 6) {
            if !prefix.isEmpty {
                Text(prefix)
            }
            OnboardingKeycaps(keys: keys)
            if !suffix.isEmpty {
                Text(suffix)
            }
        }
        .font(.system(size: 14, weight: .semibold))
    }

    private func featureTitle(_ feature: OnboardingTryModel.Feature) -> String {
        OnboardingStrings.text("feature.\(feature.rawValue)", table: "OnboardingTry")
    }
}
