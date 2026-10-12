import SwiftUI

struct WebLoginView: View {
    @ObservedObject var coordinator: WebLoginCoordinator
    @ObservedObject private var localization = AppLocalization.shared
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("auth.login.windowTitle")).font(.title2.bold())
            Text(L("auth.web.description")).foregroundStyle(.secondary)
            if coordinator.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L(coordinator.phase == .exchanging ? "auth.web.exchanging" : "auth.web.waiting"))
                }
            }
            if case let .failed(error) = coordinator.phase {
                Text(L(error.localizationKey)).foregroundStyle(.red).accessibilityIdentifier("webLoginError")
            }
            if coordinator.phase == .cancelled {
                Text(L("auth.web.cancelled")).foregroundStyle(.secondary)
            }
            if coordinator.phase == .waiting {
                Text(L("auth.web.reopenHint")).font(.callout).foregroundStyle(.secondary)
                Button(L("auth.web.reopen")) { coordinator.reopen() }
            }
            if !coordinator.isBusy {
                Button(L("auth.web.continue")) { Task { await coordinator.start() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("webLoginStart")
            }
            Button(L("auth.web.cancel")) { coordinator.cancel(); onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: coordinator.phase) { phase in
            if phase == .succeeded {
                onDismiss()
            }
        }
        .onDisappear {
            if coordinator.isBusy {
                coordinator.cancel()
            }
        }
    }
}
