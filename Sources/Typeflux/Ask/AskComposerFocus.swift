import AppKit

/// Native navigation and search can install other editable text views in the same window.
@MainActor
enum AskComposerFocus {
    static func editor(in view: NSView?) -> AskComposerTextView.Editor? {
        guard let view else { return nil }
        if let editor = view as? AskComposerTextView.Editor, editor.isEditable { return editor }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    static func requestConversationFocus(in window: NSWindow, controller: AskConversationWindowController) {
        guard controller.conversationWindow === window, window.attachedSheet == nil,
              !controller.workspacePresentation.isSearching,
              !controller.workspacePresentation.showsSidebarDrawer else { return }
        // The editor fulfills this once its native view is attached and the launcher handoff enables it.
        controller.workspacePresentation.focusComposer()
    }
}
