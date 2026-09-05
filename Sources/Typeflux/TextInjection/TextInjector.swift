import AppKit
import Foundation

struct NativeTextSelectionTarget {
    weak var textView: NSTextView?
    weak var window: NSWindow?
}

enum SelectionCaptureIntent: Equatable {
    /// Selection detection is incidental to ordinary dictation. Ambiguous clipboard
    /// responses must not turn insertion into replacement.
    case automaticInsertion

    /// The user explicitly invoked an action that operates on selected text. Apps
    /// with opaque accessibility trees may use the transactional clipboard fallback.
    case explicitSelectionAction
}

enum SelectionReplacementSafety: Equatable {
    /// The capture did not produce usable selection context.
    case none

    /// Accessibility exposed a stable, writable non-empty range.
    case directAccessibility

    /// Captured selection text authorizes paste replacement after target/text
    /// revalidation. Explicit copy-backed actions may have no accessible range.
    case verifiedPaste

    /// The text is valid context for an explicit action, but the target does not
    /// expose enough evidence for safe in-place replacement.
    case resultOnly
}

struct TextSelectionSnapshot {
    var processID: pid_t?
    var processName: String?
    var bundleIdentifier: String?
    var selectedRange: CFRange?
    var selectedText: String?
    var source: String = "none"
    var isEditable: Bool = false
    var role: String?
    var windowTitle: String?
    var isFocusedTarget: Bool = false
    var replacementContextID: UUID?
    var replacementSafety: SelectionReplacementSafety?
    var nativeTarget: NativeTextSelectionTarget?

    var hasSelection: Bool {
        let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    var hasAskSelectionContext: Bool {
        isFocusedTarget && hasSelection
    }

    var canReplaceSelection: Bool {
        if let replacementSafety {
            return hasAskSelectionContext && (
                replacementSafety == .directAccessibility ||
                    replacementSafety == .verifiedPaste
            )
        }
        return hasAskSelectionContext && (
            isEditable ||
                source == "clipboard-copy"
        )
    }

    var canSafelyRestoreSelection: Bool {
        // Accessibility-backed selections are the only ones we can reliably restore
        // after focus changes. Other editable selections may still be replaceable if
        // they remain active when we send the replacement keystrokes.
        canReplaceSelection && source == "accessibility"
    }
}

struct CurrentInputTextSnapshot {
    var processID: pid_t?
    var processName: String?
    var bundleIdentifier: String?
    var role: String?
    var text: String?
    var selectedRange: CFRange?
    var isEditable: Bool = false
    var isFocusedTarget: Bool = false
    var failureReason: String?
    var documentURL: URL?
    var textSource: String?
}

protocol TextInjector {
    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot
    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot
    func currentInputText() async -> String?
    @MainActor
    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult
}

enum TextInjectionMethod: String, Sendable {
    case ax
    case paste
}

enum TextDeliveryDestination {
    case currentInput
    case selection(TextSelectionSnapshot)
}

enum TextDeliveryResult: Equatable {
    case delivered(TextInjectionMethod)
    case unconfirmed(TextInjectionMethod)
    case notApplied(TextInjectionMethod)
}

enum TextDeliveryError: String, Error, Equatable {
    case emptyOutput
    case busy
    case noInput
    case targetChanged
    case selectionChanged
    case permissionRequired
    case clipboardUnavailable
    case eventUnavailable
}
