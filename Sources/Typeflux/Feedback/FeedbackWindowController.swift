import AppKit
import SwiftUI

/// The feedback window: one normal window, independent of Settings, that can be dragged,
/// resized and captured on its own. Closing it keeps the draft; the model outlives the window.
@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindowController()
    static let frameAutosaveName = "FeedbackWindow.v1"

    let model: FeedbackWindowModel
    private(set) var window: NSWindow?
    private var settingsStore: SettingsStore?
    /// Follows Settings › Interface Style, like the notebook and usage guide windows.
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: settingsStore ?? SettingsStore())
    private var isCapturing = false
    private let captureRegion: () async -> Data?

    /// `captureRegion` lets the user select a screen region and returns the PNG, or nil when
    /// the selection was cancelled.
    init(
        model: FeedbackWindowModel? = nil,
        captureRegion: @escaping () async -> Data? = FeedbackScreenshotCapture.selectRegion
    ) {
        self.model = model ?? FeedbackWindowModel(
            defaultContact: { AuthState.shared.userProfile?.email ?? "" }
        )
        self.captureRegion = captureRegion
        super.init()
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    /// Opens the window, or brings it forward when it is already open.
    func show(settingsStore: SettingsStore? = nil) {
        if let settingsStore {
            self.settingsStore = settingsStore
        }
        let window = window ?? makeWindow()
        if !window.isVisible {
            model.windowWillShow()
        }
        window.title = L("feedback.direct.title")
        applyAppearance(to: window)
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        // AppKit can recalculate content limits when the unified toolbar first attaches.
        window.contentMinSize = FeedbackWindowView.minimumSize
        NSApp.activate(ignoringOtherApps: true)
        model.editor.focus()
    }

    func close() {
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    /// A submission in flight cannot be abandoned by closing.
    func windowShouldClose(_: NSWindow) -> Bool {
        !model.isSubmitting
    }

    func windowWillClose(_: Notification) {
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: FeedbackWindowView.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Translucent like the notebook window, so Liquid Glass shows the desktop behind it.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("feedback.direct.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the 52pt height of the other windows.
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.feedback.toolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.feedback")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = FeedbackWindowView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onCaptureScreenshot: { [weak self] in self?.captureScreenshot() }
        )
        .interfaceStyle(following: interfaceStyleObserver)
        let hosting = TransparentAskHostingView(rootView: AnyView(root))
        // The window owns its minimum, like the word book window; the view must not add the title bar inset.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = FeedbackWindowView.minimumSize
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(FeedbackWindowView.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window
        return window
    }

    private func applyAppearance(to window: NSWindow) {
        switch settingsStore?.appearanceMode {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
    }

    // MARK: - Screenshot

    /// Hides the window, lets the user select a screen region and adds the result to the body.
    func captureScreenshot() {
        guard !isCapturing, model.canAddAttachments, let window else { return }
        isCapturing = true
        window.orderOut(nil)
        Task { [weak self] in
            let data = await self?.captureRegion()
            guard let self else { return }
            isCapturing = false
            show()
            if let data {
                model.addImageData(data, filename: FeedbackEditorView.screenshotName())
            }
        }
    }
}

/// Interactive region capture through the system's `screencapture`, which shows the standard
/// selection overlay and needs the same Screen Recording permission as the app's own screenshots.
enum FeedbackScreenshotCapture {
    static func selectRegion() async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("typeflux-feedback-shot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: output) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", output.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            // Escape leaves no file; an empty file means nothing was captured either.
            guard let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
            return data
        }.value
    }
}
