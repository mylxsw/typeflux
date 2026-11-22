import AppKit

/// A focus handoff belongs to one attachment. Discard it if another control
/// takes focus before AppKit is ready to start editing.
@MainActor
final class MountedEditorFocus {
    private var attempt: Task<Void, Never>?

    func request(_ editor: NSView, while eligible: @escaping @MainActor () -> Bool = { true }) {
        attempt?.cancel()
        guard let window = editor.window else { return }
        let previous = window.firstResponder
        attempt = Task { [weak previous, weak editor, weak window] in
            await Task.yield()
            while !Task.isCancelled, let editor, let window, editor.window === window, eligible() {
                let responder = window.firstResponder
                if responder === editor { return }
                if let field = editor as? NSTextField, let current = field.currentEditor(), responder === current { return }
                if let responder, responder !== previous, responder !== window,
                   let other = responder as? NSView, other.window === window { return }
                // Setting a window's responder doesn't activate the window.
                if !editor.isHiddenOrHasHiddenAncestor { window.makeFirstResponder(editor) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

}
