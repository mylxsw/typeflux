import AppKit

/// Resolve mode commands in the owning window before toolbar or menu keyboard equivalents.
final class AskNotesWindow: NSWindow {
    weak var notesModel: AskNotesViewModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "e",
              flags == .command || flags == [.command, .option] else {
            return super.performKeyEquivalent(with: event)
        }
        guard isVisible, attachedSheet == nil, let model = notesModel,
              model.selected != nil, !model.selecting, !model.inTrash else { return false }
        if flags.contains(.option) {
            model.setMode(model.mode == .split ? .read : .split)
        } else {
            model.toggleEditing()
        }
        return true
    }
}
