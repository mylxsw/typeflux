import AppKit
import ApplicationServices

extension AXTextInjector {
    func readOnlySelectionSnapshot(
        target: ExternalSelectionCaptureTarget,
        cancellation: SelectionReplacementCancellationToken
    ) throws -> TextSelectionSnapshot {
        let processID = target.processID
        let window = processID.flatMap(focusedWindowElement(for:))
        let focused = processID.flatMap(deliveryFocusedElement(for:))
        let budget = ReadOnlySelectionBudget()
        let result = try ReadOnlySelection.capture(
            readAX: {
                ReadOnlySelection.find(
                    roots: [focused, window].compactMap { $0 }, budget: budget,
                    read: { self.readOnlySelectedText(from: $0, budget: budget) },
                    children: { element in
                        guard budget.take() else { return [] }
                        var children: CFArray?
                        // Fetch a bounded slice without materializing the entire AX array.
                        guard AXUIElementCopyAttributeValues(
                            element, kAXChildrenAttribute as CFString, 0, 32, &children
                        ) == .success, let children = children as? [AXUIElement] else { return [] }
                        return children
                    },
                    matches: { CFEqual($0, $1) }
                )?.text
            },
            copy: {
                self.logger.debug("read-only AX selection unavailable — trying clipboard-copy")
                let text = self.readSelectedTextViaCopy(
                    processID: processID, milliseconds: Self.copySelectionTimeoutMilliseconds
                )
                if text == nil { self.logger.debug("clipboard-copy attempted but returned no text") }
                return text
            },
            targetMatches: { self.readOnlyTargetMatches(processID: processID, window: window) },
            checkCancellation: { try cancellation.checkCancellation() }
        )
        logger.debug("read-only selection source=\(result.source, privacy: .public) textLength=\(result.text?.utf16.count ?? 0)")
        return TextSelectionSnapshot(
            processID: processID, processName: target.processName,
            bundleIdentifier: target.bundleIdentifier, selectedText: result.text,
            source: result.source, windowTitle: window.flatMap(windowTitle(of:)),
            isFocusedTarget: result.text != nil
        ).readOnlyContext()
    }

    private func readOnlyTargetMatches(processID: pid_t?, window: AXUIElement?) -> Bool {
        guard let processID, processID == frontmostProcessID() else { return false }
        let currentWindow = focusedWindowElement(for: processID)
        switch (window, currentWindow) {
        case let (original?, current?): return CFEqual(original, current)
        case (nil, nil): return true
        default: return false
        }
    }

    func readOnlySelectedText(
        from element: AXUIElement, budget: ReadOnlySelectionBudget,
        attributeValue: ((String) -> AnyObject?)? = nil,
        parameterizedText: ((CFRange) -> String?)? = nil
    ) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.replacementAXMessagingTimeout)
        func attribute(_ name: String) -> AnyObject? {
            guard budget.take() else { return nil }
            if let attributeValue { return attributeValue(name) }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func string(_ value: AnyObject?) -> String? {
            (value as? String) ?? (value as? NSAttributedString)?.string
        }
        func range(_ value: AnyObject?) -> CFRange? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let typed = unsafeBitCast(value, to: AXValue.self)
            guard AXValueGetType(typed) == .cfRange else { return nil }
            var range = CFRange()
            return AXValueGetValue(typed, .cfRange, &range) ? range : nil
        }
        let selectedText = string(attribute(kAXSelectedTextAttribute as String))
        let selectedRange = range(attribute(kAXSelectedTextRangeAttribute as String))
        return ReadOnlySelection.text(
            selectedText: {
                guard selectedText != nil else { return nil }
                let value = string(attribute(kAXValueAttribute as String))
                let placeholder = string(attribute(kAXPlaceholderValueAttribute as String))
                let title = string(attribute(kAXTitleAttribute as String))
                let role = string(attribute(kAXRoleAttribute as String))
                guard budget.take() else { return nil }
                return Self.validSelectionText(
                    selectedText: selectedText, selectedRange: selectedRange,
                    value: value, placeholder: placeholder, title: title, role: role
                )
            },
            ranges: {
                if let selectedRange, selectedRange.length > 0 { return [selectedRange] }
                guard let values = attribute(kAXSelectedTextRangesAttribute as String) as? [AnyObject],
                      !values.isEmpty, values.count <= 16 else { return [] }
                let ranges = values.compactMap(range)
                return ranges.count == values.count ? ranges : []
            },
            stringForRange: { selectedRange in
                guard budget.take() else { return nil }
                if let parameterizedText { return parameterizedText(selectedRange) }
                var selectedRange = selectedRange
                guard let parameter = AXValueCreate(.cfRange, &selectedRange) else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
                ) == .success else { return nil }
                return value as? String
            },
            value: { string(attribute(kAXValueAttribute as String)) }
        )
    }
}
