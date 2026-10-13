import AppKit

/// Exercises real panel focus in the command-line runner without application activation.
final class TypefluxNonactivatingTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
