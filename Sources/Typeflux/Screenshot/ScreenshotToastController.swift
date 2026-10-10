import AppKit
import SwiftUI

/// A short message at the bottom of the screen with the pointer: "Copied",
/// "Saved to Desktop · Show in Finder". It takes no focus and goes away by itself.
@MainActor
final class ScreenshotToastController: ScreenshotToastPresenting {
    struct Content: Equatable {
        var message: String
        var symbol: String
        var isError = false
        /// "Show in Finder" reveals this file.
        var revealURL: URL?
        var duration: TimeInterval = 2
    }

    private(set) var panel: NSPanel?
    private(set) var content: Content?
    private var hideWork: DispatchWorkItem?
    private let reveal: (URL) -> Void

    init(reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.reveal = reveal
    }

    static func content(for toast: ScreenshotToast) -> Content {
        switch toast {
        case .copied:
            Content(message: L("screenshot.toast.copied"), symbol: "doc.on.clipboard")
        case let .saved(url):
            Content(message: L("screenshot.toast.saved", url.deletingLastPathComponent().lastPathComponent),
                    symbol: "checkmark.circle", revealURL: url, duration: 4)
        case let .savedAsCopy(reason):
            Content(message: L("screenshot.toast.savedAsCopy", reason), symbol: "exclamationmark.triangle",
                    isError: true, duration: 5)
        case let .colorCopied(hex):
            Content(message: L("screenshot.toast.colorCopied", hex), symbol: "eyedropper")
        case .busy:
            Content(message: L("screenshot.toast.busy"), symbol: "hourglass")
        case .failed:
            Content(message: L("screenshot.toast.failed"), symbol: "exclamationmark.triangle", isError: true,
                    duration: 4)
        }
    }

    func show(_ toast: ScreenshotToast) {
        let content = Self.content(for: toast)
        self.content = content
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ScreenshotToastView(content: content) { [weak self] in
            if let url = content.revealURL { self?.reveal(url) }
            self?.hide()
        })
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(CGRect(x: area.midX - size.width / 2, y: area.minY + 72, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + content.duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        content = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        // Above the screenshot overlay, so a picked color's notice shows over it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct ScreenshotToastView: View {
    let content: ScreenshotToastController.Content
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: content.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(content.isError ? Color.orange : Color(nsColor: ScreenshotOverlayChromeView.accent))
            Text(content.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if content.revealURL != nil {
                Button(L("screenshot.toast.showInFinder"), action: onReveal)
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12)))
        .fixedSize()
    }
}
