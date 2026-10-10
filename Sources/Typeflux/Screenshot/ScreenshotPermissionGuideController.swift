import AppKit
import SwiftUI

/// Explains how to grant Screen Recording access when a screenshot cannot start:
/// open System Settings, check again, restart Typeflux, or leave it for later.
@MainActor
final class ScreenshotPermissionGuideController: ScreenshotPermissionGuidePresenting {
    final class Model: ObservableObject {
        /// "Check again" found no access yet.
        @Published var stillMissing = false
    }

    private(set) var window: NSPanel?
    private(set) var model = Model()
    private var actions: ScreenshotPermissionGuideActions?

    var isVisible: Bool { window?.isVisible == true }

    func show(actions: ScreenshotPermissionGuideActions) {
        self.actions = actions
        model.stillMissing = false
        let window = window ?? makeWindow()
        self.window = window
        window.title = L("screenshot.permission.title")
        window.contentView = NSHostingView(rootView: ScreenshotPermissionGuideView(
            model: model,
            openSettings: { [weak self] in self?.actions?.openSettings() },
            recheck: { [weak self] in self?.recheck() },
            restart: { [weak self] in self?.actions?.restart() },
            later: { [weak self] in self?.actions?.later() }
        ))
        window.setContentSize(window.contentView?.fittingSize ?? CGSize(width: 460, height: 320))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: area.midX - window.frame.width / 2,
                                          y: area.midY - window.frame.height / 2 + area.height / 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.contentView = nil
        actions = nil
    }

    /// Runs "Check again"; the guide closes itself when access is there.
    func recheck() {
        guard let actions else { return }
        model.stillMissing = !actions.recheck()
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 320),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

struct ScreenshotPermissionGuideView: View {
    @ObservedObject var model: ScreenshotPermissionGuideController.Model
    let openSettings: () -> Void
    let recheck: () -> Void
    let restart: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("screenshot.permission.title"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("screenshot.permission.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, L("screenshot.permission.step1"))
                step(2, L("screenshot.permission.step2"))
                step(3, L("screenshot.permission.step3"))
            }
            if model.stillMissing {
                Label(L("screenshot.permission.stillMissing"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L("screenshot.permission.later"), action: later)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("screenshot.permission.restart"), action: restart)
                Button(L("screenshot.permission.recheck"), action: recheck)
                Button(L("screenshot.permission.openSettings"), action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 520)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(StudioTheme.accent))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Starts a fresh copy of the app after this one quits: some macOS versions only apply
/// a new Screen Recording grant to a new process.
enum ScreenshotAppRelauncher {
    static func command(bundlePath: String) -> (executable: URL, arguments: [String]) {
        // The path is passed as an argument, never spliced into the script.
        (URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 1; /usr/bin/open \"$0\"", bundlePath])
    }

    static func relaunch(bundleURL: URL = Bundle.main.bundleURL) {
        let command = command(bundlePath: bundleURL.path)
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        do {
            try process.run()
        } catch {
            ErrorLogStore.shared.log("Screenshot: relaunch failed: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
