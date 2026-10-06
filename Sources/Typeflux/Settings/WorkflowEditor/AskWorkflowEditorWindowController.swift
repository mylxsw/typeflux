import AppKit
import SwiftUI

/// The one workflow editor window. Settings, the launcher's error card and the
/// new-workflow menu all open it here; it switches to the workflow they name.
@MainActor
final class AskWorkflowEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWorkflowEditorWindowController()

    /// The Ask workspace's API, session and models, so the assistant's conversations
    /// are ordinary Ask conversations. `DIContainer` supplies it.
    var assistantDependencies: (() -> AskWorkflowAssistant.Dependencies?)?
    private let settings: SettingsStore
    private let store: AskWorkflowStore
    /// Asks what to do with unsaved edits when the window closes; tests answer it.
    var confirmClose: () -> NSApplication.ModalResponse = AskWorkflowEditorWindowController.askAboutUnsavedEdits
    private(set) var window: NSWindow?
    private(set) var model: AskWorkflowEditorModel?

    init(store: AskWorkflowStore = .shared, settings: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = settings
    }

    /// Opens the editor, at a workflow and optionally a line of one of its files.
    func show(workflowID: String? = nil, path: String? = nil, line: Int? = nil) {
        let model = ensureModel()
        model.navigate(to: workflowID, path: path, line: line)
        present()
    }

    /// Opens the editor with the new-workflow sheet.
    func showNew(_ mode: AskWorkflowNewSheet.Mode = .assistant) {
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .askWorkflowEditorCreate, object: mode)
        }
    }

    /// Opens a failed workflow and asks the assistant to fix it with what the launcher saw.
    func fix(workflowID: String, query: String, error: String) {
        show(workflowID: workflowID)
        guard let model, model.workflowID == workflowID else { return }
        model.testQuery = query
        model.assistant.send(L("ask.workflow.assistant.fix.launcher", query, error))
    }

    private func ensureModel() -> AskWorkflowEditorModel {
        if let model {
            return model
        }
        let dependencies = assistantDependencies?() ?? Self.fallbackDependencies(settings: settings)
        let assistant = AskWorkflowAssistant(dependencies: dependencies)
        var tester = AskWorkflowTester(record: { entry in Task { @MainActor in AskWorkflowLog.shared.add(entry) } })
        tester.language = settings.appLanguage
        let model = AskWorkflowEditorModel(store: store, settings: settings, assistant: assistant, tester: tester)
        let staging = model.staging
        Task.detached(priority: .utility) { staging.prune() }
        self.model = model
        return model
    }

    /// Without the Ask workspace (its storage failed to open) the assistant still runs
    /// through a routed API of its own.
    private static func fallbackDependencies(settings: SettingsStore) -> AskWorkflowAssistant.Dependencies {
        let deviceKey = "ask.deviceId"
        let deviceId = settings.defaults.string(forKey: deviceKey) ?? UUID().uuidString
        settings.defaults.set(deviceId, forKey: deviceKey)
        return .init(api: AskRoutedAPI(cloud: AskAPIClient(), local: AskLocalEngine()),
                     session: { AskRoutedAPI.session(
                         token: AuthState.shared.accessToken,
                         owner: AuthState.shared.userProfile?.id
                     ) },
                     deviceId: deviceId, modelLibrary: .shared,
                     prefersLocal: { settings.askNewConversationsStayLocal }, defaults: settings.defaults)
    }

    private func present() {
        guard let model else { return }
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = AskWorkflowEditorView(model: model, store: model.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("ask.workflow.editor.title")
        // The header row is the title bar: the traffic lights sit over the sidebar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 960, height: 560)
        window.setFrameAutosaveName("AskWorkflowEditor")
        if window.frame.origin == .zero {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Unsaved edits are saved, thrown away, or the window stays open.
    func windowShouldClose(_: NSWindow) -> Bool {
        guard let model, model.isDirty || model.generation != nil else { return true }
        switch confirmClose() {
        case .alertFirstButtonReturn: return model.save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private static func askAboutUnsavedEdits() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = L("ask.workflow.editor.unsavedTitle")
        alert.informativeText = L("ask.workflow.editor.unsavedBody")
        alert.addButton(withTitle: L("ask.workflow.editor.save"))
        alert.addButton(withTitle: L("ask.workflow.editor.discard"))
        alert.addButton(withTitle: L("ask.workflow.cancel"))
        return alert.runModal()
    }

    func windowWillClose(_: Notification) {
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
        model?.close()
        window = nil
    }
}
