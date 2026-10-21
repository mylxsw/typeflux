import SwiftUI

struct ChatAppIconView: View {
    @Bindable var controller: ChatAppIconController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the icon shown on your Home Screen.")
                    .font(.subheadline).foregroundStyle(ChatTheme.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(ChatAppIcon.allCases) { icon in
                        iconButton(icon)
                    }
                }
                if controller.isChanging {
                    ProgressView("Changing app icon…").frame(maxWidth: .infinity)
                }
                if !controller.supportsAlternateIcons {
                    Text("App icon changes are unavailable on this device.")
                        .font(.footnote).foregroundStyle(ChatTheme.secondary)
                }
            }
            .padding(16).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(ChatTheme.background)
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.appIcon.root")
        .onAppear { controller.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refresh()
            }
        }
        .alert("Unable to change app icon", isPresented: $controller.changeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again. Your current app icon is unchanged.")
        }
    }

    private func iconButton(_ icon: ChatAppIcon) -> some View {
        let selected = controller.selected == icon
        return Button {
            Task { await controller.select(icon) }
        } label: {
            VStack(spacing: 10) {
                Image(icon.previewName)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                Text(icon.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary).multilineTextAlignment(.center)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ChatTheme.accent : ChatTheme.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 132).padding(8)
            .background(ChatTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? ChatTheme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isChanging || !controller.supportsAlternateIcons)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon." + icon.rawValue)
    }
}
