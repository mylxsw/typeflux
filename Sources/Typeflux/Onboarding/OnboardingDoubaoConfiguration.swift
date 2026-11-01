import SwiftUI

/// Keep the model resource visible alongside the credentials used by this integration.
struct OnboardingDoubaoConfiguration: View {
    @ObservedObject var model: OnboardingSpeechModel
    @State private var showsGuide = false

    private func text(_ key: String) -> String {
        OnboardingStrings.text(key, table: "OnboardingSpeech")
    }

    private var resources: [OnboardingModelPickerItem] {
        [
            .init(id: DoubaoASRDefaults.resourceID, title: text("doubao.model2Duration")),
            .init(id: "volc.seedasr.sauc.concurrent", title: text("doubao.model2Concurrent")),
            .init(id: "volc.bigasr.sauc.duration", title: text("doubao.model1Duration")),
            .init(id: "volc.bigasr.sauc.concurrent", title: text("doubao.model1Concurrent"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Button { showsGuide.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsGuide ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Label(text("doubao.guideTitle"), systemImage: "list.bullet.clipboard")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("doubao.guideTitle"))
                .accessibilityValue(text(showsGuide ? "doubao.guideExpanded" : "doubao.guideCollapsed"))
                if showsGuide {
                    VStack(alignment: .leading, spacing: 8) {
                        guideStep("1", text("doubao.guideService"))
                        guideStep("2", text("doubao.guideCredentials"))
                        Text(text("doubao.testHint"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = model.apiKeyHelpURL {
                            Link(text("doubao.openGuide"), destination: url)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .top, spacing: 12) {
                field(text("field.appId")) {
                    TextField("App ID", text: $model.doubaoAppID)
                        .accessibilityIdentifier("onboarding.speech.doubaoAppID")
                }
                field(text("field.accessToken")) {
                    SecureField(text("placeholder.pasteAccessToken"), text: $model.doubaoAccessToken)
                        .accessibilityIdentifier("onboarding.speech.doubaoAccessToken")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(text("doubao.resourceLabel"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    OnboardingModelPicker(
                        items: resources, selection: model.doubaoResourceID,
                        identifier: "onboarding.speech.doubaoResourcePresets", height: 24
                    ) { model.doubaoResourceID = $0 } label: {
                        HStack(spacing: 4) {
                            Text(text("doubao.presets"))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                TextField(DoubaoASRDefaults.resourceID, text: $model.doubaoResourceID)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(text("doubao.resourceLabel"))
                    .accessibilityIdentifier("onboarding.speech.doubaoResourceID")
                    .modifier(DoubaoInputSurface())
                Text(text("doubao.resourceHint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideStep(_ number: String, _ instruction: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
                .background(.primary.opacity(0.06), in: Circle())
            Text(instruction).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ title: String, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            input().accessibilityLabel(title).modifier(DoubaoInputSurface())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DoubaoInputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, 10).frame(height: 34)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}
