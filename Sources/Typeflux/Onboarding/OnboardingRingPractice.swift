import AppKit
import OpieMenu
import SwiftUI

/// Use the live ring renderer and saved actions; practice selections stay inside onboarding.
struct OnboardingRingPractice: View {
    @ObservedObject var model: OnboardingTryModel
    @State private var pointedTitle: String?
    @State private var selectedTitle: String?

    private func text(_ key: String) -> String {
        OnboardingStrings.text(key, table: "OnboardingTry")
    }

    var body: some View {
        HStack(spacing: 16) {
            OnboardingNativeRingPreview(configuration: model.ringConfiguration,
                                        onHover: { id in
                                            pointedTitle = model.ringConfiguration.actions
                                                .first { $0.id.uuidString == id }?
                                                .title
                                        }, onSelect: select)
                .accessibilityRepresentation {
                    VStack {
                        ForEach(model.ringConfiguration.actions) { action in
                            Button(action.title) { select(action.id.uuidString) }
                        }
                    }
                }
                .frame(width: 368, height: 320)
            VStack(alignment: .leading, spacing: 16) {
                Text(text("ring.guideTitle")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    step("1", text("ring.hold"))
                    let keys = model.shortcutKeys(for: .ring)
                    if keys.isEmpty {
                        Text(text("status.notSet")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        OnboardingKeycaps(keys: keys)
                    }
                }
                step("2", text("ring.move"))
                step("3", text("ring.release"))
                Divider().opacity(0.5)
                Text(model.ringConfiguration.actions.isEmpty ? text("ring.empty") : text("ring.practiceHint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if let title = selectedTitle ?? pointedTitle {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(Color.accentColor)
                }
                Button { model.markTried(.ring) } label: {
                    Text(text("button.tried"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13).frame(height: 30)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 196, alignment: .leading)
        }
    }

    private func step(_ number: String, _ title: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number).font(.system(size: 10, weight: .semibold))
                .frame(width: 17, height: 17)
                .background(Color.primary.opacity(0.07), in: Circle())
            Text(title).font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
    }

    private func select(_ id: String) {
        guard let action = model.ringConfiguration.actions.first(where: { $0.id.uuidString == id }) else { return }
        selectedTitle = action.title
        model.markTried(.ring)
    }
}

private struct OnboardingNativeRingPreview: NSViewRepresentable {
    let configuration: RingConfiguration
    let onHover: (String) -> Void
    let onSelect: (String) -> Void

    final class Coordinator {
        var configuration: RingConfiguration?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> OpieMenuPreviewView {
        let view = OpieMenuPreviewView(items: items, centerTitle: centerTitle,
                                       style: OpieRingMenu.style(configuration.style), scale: 0.8)
        view.setAccessibilityIdentifier("onboarding.try.ring.preview")
        context.coordinator.configuration = configuration
        return view
    }

    func updateNSView(_ view: OpieMenuPreviewView, context: Context) {
        view.onHover = { onHover($0.id) }
        view.onSelect = { onSelect($0.id) }
        // Hover and completion redraw the SwiftUI page without resetting the ring's interaction.
        if context.coordinator.configuration != configuration {
            view.configure(items: items, centerTitle: centerTitle, style: OpieRingMenu.style(configuration.style))
            context.coordinator.configuration = configuration
        }
    }

    static func dismantleNSView(_ view: OpieMenuPreviewView, coordinator _: Coordinator) {
        view.stop()
    }

    private var centerTitle: String {
        configuration.centerTitle.isEmpty ? RingConfiguration.defaultCenterTitle : configuration.centerTitle
    }

    private var items: [OpieMenuItem] {
        configuration.actions.map { action in
            let icon: OpieMenuIcon = RingActionIcon.appIcon(for: action).map(OpieMenuIcon.image)
                ?? .systemSymbol(action.symbol)
            return OpieMenuItem(id: action.id.uuidString, title: RingSettingsPresentation.sliceLabel(action.title),
                                icon: icon)
        }
    }
}
