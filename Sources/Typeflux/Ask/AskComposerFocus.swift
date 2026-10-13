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
        // Native navigation can rebuild the responder tree after deminiaturization.
        DispatchQueue.main.async { [weak controller, weak window] in
            guard let controller, let window, controller.conversationWindow === window,
                  window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
                  !controller.workspacePresentation.isSearching,
                  !controller.workspacePresentation.showsSidebarDrawer else { return }
            guard let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            if let editor = editor(in: content) { window.makeFirstResponder(editor) }
        }
    }
}
