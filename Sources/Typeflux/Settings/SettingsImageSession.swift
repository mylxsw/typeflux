import AppKit
import SwiftUI

/// Window-owned local projections. Account changes retire the old authorization permanently.
@MainActor final class SettingsImageSession: ObservableObject {
    let scope = AskImagePresentationScope()
    @Published private(set) var revision = UUID()
    private var observers: [NSObjectProtocol] = []
    init() {
        scope.setVisible(false)
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setVisible(false) }
            })
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        Task { @MainActor [scope] in scope.setVisible(false) }
    }
    func setVisible(_ visible: Bool) {
        scope.setVisible(visible); revision = UUID()
    }
    var access: AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
}

/// SwiftUI can remain mounted after orderOut; native visibility owns retirement.
final class SettingsImageWindow: NSWindow {
    let images = SettingsImageSession()
    override func makeKeyAndOrderFront(_ sender: Any?) { super.makeKeyAndOrderFront(sender); images.setVisible(true) }
    override func orderFront(_ sender: Any?) { super.orderFront(sender); images.setVisible(true) }
    override func orderOut(_ sender: Any?) { images.setVisible(false); super.orderOut(sender) }
    override func close() { images.setVisible(false); super.close() }
    override func miniaturize(_ sender: Any?) { images.setVisible(false); super.miniaturize(sender) }
    override func deminiaturize(_ sender: Any?) { super.deminiaturize(sender); images.setVisible(true) }
}

struct SettingsImageContent<Content: View>: View {
    @ObservedObject var session: SettingsImageSession
    let content: Content
    var body: some View { content.environment(\.askContextImageAccess, session.access) }
}
