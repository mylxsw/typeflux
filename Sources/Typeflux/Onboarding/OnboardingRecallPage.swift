import SwiftUI

/// One lasting takeaway after practice: the launcher is also the way back to help.
struct OnboardingRecallPage: View {
    @ObservedObject var viewModel: OnboardingViewModel

    private func text(_ key: String) -> String {
        OnboardingStrings.text(key, table: OnboardingStep.recall.table)
    }

    var body: some View {
        VStack(spacing: 28) {
            OnboardingEditorialHeader(eyebrow: text("eyebrow"), title: text("title"),
                                      subtitle: text("subtitle"), pill: OnboardingStep.recall.pill,
                                      centered: true)
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Text(text("open")).font(.system(size: 14, weight: .semibold))
                if let binding = viewModel.settingsStore.askHotkey {
                    OnboardingKeycaps(keys: HotkeyFormat.components(binding)
                        + (HotkeyFormat.pressCount(binding).map { ["×\($0)"] } ?? []))
                        .scaleEffect(1.4)
                        .padding(.vertical, 8)
                } else {
                    Text(text("menu")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                LauncherGuidePreview(keyword: "help", title: L("help.title"))
                    .frame(maxWidth: 460)
                Text(text("help")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34).padding(.top, 6).padding(.bottom, 20)
    }
}

/// A compact launcher example shared by onboarding and the guide.
struct LauncherGuidePreview: View {
    let keyword: String
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(keyword).font(.system(size: 19, weight: .medium, design: .monospaced))
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 58)
            Divider().padding(.horizontal, 12)
            HStack(spacing: 12) {
                Image(systemName: keyword == "help" ? "questionmark.circle" : "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                OnboardingKeycaps(keys: ["↩"])
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(6)
        }
        .background(colorScheme == .dark ? Color(white: 0.14) : Color.white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.05), radius: 16, y: 8)
    }
}
