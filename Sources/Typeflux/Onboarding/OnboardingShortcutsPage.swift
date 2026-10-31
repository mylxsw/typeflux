import AppKit
import SwiftUI

struct OnboardingShortcutsPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingShortcutsModel
    @Environment(\.colorScheme) private var colorScheme
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private func text(_ key: String) -> String {
        OnboardingShortcutsModel.text(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingEditorialHeader(eyebrow: text("eyebrow"), title: text("title"),
                                      subtitle: text("subtitle"), pill: "03 / 04")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    group("voice", targets: Array(OnboardingShortcutsModel.targets.prefix(3)))
                    group("tools", targets: Array(OnboardingShortcutsModel.targets.dropFirst(3))).padding(.top, 8)
                    HStack {
                        Button { model.restoreAll() } label: {
                            Label(text("resetAll"), systemImage: "arrow.counterclockwise")
                        }.buttonStyle(.plain)
                        Spacer()
                        Text(text("moreShortcuts")).foregroundStyle(.tertiary)
                    }.font(.system(size: 11.5)).padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 34).padding(.top, 6)
        .overlay(alignment: .bottomTrailing) {
            if model.guideVisible {
                OnboardingSystemSettingsGuide(title: text("guideTitle"),
                                              steps: [
                                                  text("guideSetting"),
                                                  text(viewModel.isGlobeKeyReady ? "completed" : "detecting")
                                              ],
                                              dismissTitle: "×") { model.guideVisible = false }
                    .padding(.trailing, 34).padding(.bottom, 12)
            }
        }
        .onAppear { model.refresh() }
        .onDisappear { model.stopRecording(); model.guideVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private func group(_ title: String, targets: [HotkeyTarget]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(title)).font(.system(size: 9.5, weight: .bold)).tracking(1.4).foregroundStyle(.tertiary)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(targets, id: \.self) { target in card(target) }
            }
        }
    }

    private func key(_ target: HotkeyTarget) -> String {
        switch target {
        case let .builtIn(key): key.rawValue
        case let .action(key): key.rawValue
        case .keyword: ""
        }
    }

    private func card(_ target: HotkeyTarget) -> some View {
        let recording = model.recordingTarget == target
        let conflict = model.conflict(target)
        let voice = target == .builtIn(.activation) || target == .builtIn(.auxiliary)
        return HStack(spacing: 12) {
            Image(systemName: model.shortcuts.row(for: target)?.icon ?? "keyboard")
                .foregroundStyle(Color.accentColor).frame(width: 32, height: 32)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(text(key(target))).font(.system(size: 13, weight: .semibold))
                Text(recording ? text(voice ? "cancelVoice" : "cancel") : conflict ?? text(key(target) + "Hint"))
                    .font(.system(size: 11)).foregroundStyle(recording ? Color.accentColor
                        : conflict == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !recording, model.isGlobeConflict(target) {
                Button(text(model.guideVisible ? "waiting" : "fix")) { model.openGuide() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11))
            } else if target == .builtIn(.ask), !recording, model.canOfferAlternative {
                Button(text("alternative")) { model.apply(model.alternative, to: target) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11))
            }
            Button { model.startRecording(target) } label: {
                if !recording, let binding = model.binding(target) {
                    OnboardingKeycaps(keys: HotkeyFormat.components(binding)
                        + (HotkeyFormat.pressCount(binding).map { ["×\($0)"] } ?? []))
                } else {
                    HStack(spacing: 6) {
                        if recording {
                            ProgressView().controlSize(.mini)
                        }
                        Text(text(recording ? "recording" : "unset"))
                    }
                    .font(.system(size: 12, weight: .semibold)).fixedSize()
                    .padding(.horizontal, 7).frame(height: 26)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.10), lineWidth: 1))
                }
            }.buttonStyle(.plain).accessibilityLabel(text(key(target)))
            TFMenuButton(title: text(key(target)), systemImage: "ellipsis", kind: .plain, size: .small,
                         iconOnly: true, actions: model.menuActions(target),
                         identifier: "onboarding.shortcuts." + key(target))
                .frame(width: 22)
        }
        .padding(.leading, 14).padding(.trailing, 12).frame(height: 60)
        .background(colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(recording ? Color.accentColor
                : conflict == nil ? Color.primary.opacity(0.08) : Color.orange.opacity(0.55),
            lineWidth: recording ? 1.5 : 1))
    }
}
