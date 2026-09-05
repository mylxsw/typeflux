import ApplicationServices
import Foundation

/// AXValue can include placeholder/decoration text instead of editor content.
/// Prefer the editor's character model; never guess from an application name.
enum TextDeliveryContent {
    static func value(
        raw: String?, characterCount: Int?, rangedText: String?,
        placeholder: String?, selection: CFRange?
    ) -> String? {
        if let characterCount {
            guard characterCount >= 0 else { return nil }
            if characterCount == 0 { return "" }
            if let rangedText, rangedText.utf16.count == characterCount { return rangedText }
            guard let raw, raw.utf16.count == characterCount else { return nil }
            return raw
        }
        if let raw, let placeholder,
           !placeholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           raw.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder.trimmingCharacters(in: .whitespacesAndNewlines),
           selection?.location == 0, selection?.length == 0 {
            return ""
        }
        return raw
    }
}

extension AXTextInjector {
    func deliveryContentValue(from element: AXUIElement, raw: String?, selection: CFRange?) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.replacementAXMessagingTimeout)
        var countValue: AnyObject?
        let countResult = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue)
        let count = countResult == .success ? (countValue as? NSNumber)?.intValue : nil
        var rangedText: String?
        if let count, count > 0, count <= 1_000_000 {
            var range = CFRange(location: 0, length: count)
            if let parameter = AXValueCreate(.cfRange, &range) {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
                ) == .success {
                    rangedText = value as? String
                }
            }
        }
        let placeholder = count == nil
            ? copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element) : nil
        let content = TextDeliveryContent.value(
            raw: raw, characterCount: count, rangedText: rangedText,
            placeholder: placeholder, selection: selection
        )
        NetworkDebugLogger.logMessage(
            "[Text Delivery] content rawLength=\(raw?.utf16.count ?? -1) characters=\(count ?? -1) rangeTextLength=\(rangedText?.utf16.count ?? -1) contentLength=\(content?.utf16.count ?? -1)"
        )
        return content
    }
}
