import AppKit
import SwiftUI

/// Expose the native secure input itself, including its protected AX subrole.
public struct TypefluxSecureField: NSViewRepresentable {
    @Binding private var text: String
    private let title: String

    public init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }

        public func controlTextDidEndEditing(_ notification: Notification) {
            controlTextDidChange(notification)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    public func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }

    public func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = context.environment.isEnabled
        switch context.environment.controlSize {
        case .mini: field.controlSize = .mini
        case .small: field.controlSize = .small
        case .large: field.controlSize = .large
        default: field.controlSize = .regular
        }
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.placeholderString = title
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.textField)
        field.setAccessibilitySubrole(.secureTextField)
        field.setAccessibilityLabel(title)
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSecureTextField, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.intrinsicContentSize.height)
    }

    public static func dismantleNSView(_ field: NSSecureTextField, coordinator _: Coordinator) {
        field.delegate = nil
    }
}
