import AppKit
import ApplicationServices

extension AXTextInjector {
    @MainActor
    func makeReadOnlySelectionRequest() -> ReadOnlySelectionRequest {
        var request = ReadOnlySelectionRequest.frontmost()
        // Local AppKit reads only, before the launcher takes the native editor's focus.
        if request.processID == ProcessInfo.processInfo.processIdentifier {
            request.nativeSnapshot = typefluxNativeTextTarget().map(typefluxNativeSelectionSnapshot)
                ?? typefluxReadOnlyWindowSelectionSnapshot(source: "typeflux-non-text-window")
        }
        return request
    }

    @MainActor
    func readOnlySelectionSnapshot(for request: ReadOnlySelectionRequest) async -> TextSelectionSnapshot {
        do { try await acquireTextOperation() }
        catch { return TextSelectionSnapshot(source: Task.isCancelled ? "capture-cancelled" : "capture-busy") }
        defer { deliveryInProgress = false }
        latestSelectionContext = nil
        guard !Task.isCancelled else { return TextSelectionSnapshot(source: "capture-cancelled") }
        guard request.matches(processID: frontmostProcessID()) else {
            return TextSelectionSnapshot(source: "target-changed")
        }
        if let snapshot = request.nativeSnapshot { return snapshot.readOnlyContext() }
        guard AXIsProcessTrusted() else { return TextSelectionSnapshot(source: "permission-missing") }
        let cancellation = SelectionReplacementCancellationToken()
        do {
            return try await performSelectionReplacementWork(cancellationToken: cancellation) {
                try self.readOnlySelectionSnapshot(
                    target: ExternalSelectionCaptureTarget(processID: request.processID,
                        processName: request.processName, bundleIdentifier: request.bundleIdentifier),
                    cancellation: cancellation, request: request
                )
            }
        } catch {
            return TextSelectionSnapshot(source: "capture-cancelled")
        }
    }

    func readOnlySelectionSnapshot(
        target: ExternalSelectionCaptureTarget,
        cancellation: SelectionReplacementCancellationToken,
        request: ReadOnlySelectionRequest? = nil
    ) throws -> TextSelectionSnapshot {
        let request = request ?? ReadOnlySelectionRequest(processID: target.processID,
            processName: target.processName, bundleIdentifier: target.bundleIdentifier)
        let processID = target.processID
        let budget = ReadOnlySelectionBudget()
        let diagnostics = ReadOnlySelectionDiagnostics()
        var window: AXUIElement?
        var didReadWindow = false
        // Read only the pinned app's roots. Avoid the general focus resolver's
        // independent traversal and keep root failures inside this diagnostic budget.
        func element(_ attribute: String, application: AXUIElement) -> AXUIElement? {
            guard budget.take() else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
            diagnostics.record(attribute, error: error)
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        let result = try ReadOnlySelection.capture(
            readAX: {
                guard let processID else { return nil }
                let app = AXUIElementCreateApplication(processID)
                AXUIElementSetMessagingTimeout(app, Self.replacementAXMessagingTimeout)
                window = element(kAXFocusedWindowAttribute, application: app)
                didReadWindow = true
                let focused = element(kAXFocusedUIElementAttribute, application: app)
                return ReadOnlySelection.find(
                    roots: [focused, window].compactMap { $0 }, budget: budget,
                    read: { self.readOnlySelectedText(from: $0, budget: budget, diagnostics: diagnostics) },
                    children: { element in
                        guard budget.take() else { return [] }
                        var count: CFIndex = 0
                        let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                        diagnostics.record("AXChildren.count", error: countError)
                        if countError == .success, count == 0 { return [] }
                        guard budget.take() else { return [] }
                        // Some bridges support sliced reads but not count queries.
                        let limit = countError == .success ? min(max(count, 0), 32) : 32
                        var children: CFArray?
                        let error = AXUIElementCopyAttributeValues(
                            element, kAXChildrenAttribute as CFString, 0, limit, &children
                        )
                        diagnostics.record(kAXChildrenAttribute, error: error)
                        guard error == .success, let children = children as? [AXUIElement] else { return [] }
                        if countError == .success ? count > children.count : children.count == 32 {
                            diagnostics.treeTruncated = true
                        }
                        return children
                    },
                    matches: { CFEqual($0, $1) },
                    onTruncation: { diagnostics.treeTruncated = true }
                )?.text
            },
            targetMatches: {
                guard request.matches(processID: self.frontmostProcessID()) else { return false }
                return !didReadWindow || self.readOnlyTargetMatches(processID: processID, window: window)
            },
            checkCancellation: { try cancellation.checkCancellation() }
        )
        let status = result.source == "target-changed" ? result.source
            : diagnostics.status(text: result.text, budget: budget)
        request.log(status: status, details: diagnostics.details(budget: budget))
        return TextSelectionSnapshot(
            processID: processID, processName: target.processName,
            bundleIdentifier: target.bundleIdentifier, selectedText: result.text,
            source: status, windowTitle: window.flatMap(windowTitle(of:)),
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
        diagnostics: ReadOnlySelectionDiagnostics = ReadOnlySelectionDiagnostics(),
        attributeRead: ((String) -> (AXError, AnyObject?))? = nil,
        parameterizedText: ((CFRange) -> String?)? = nil
    ) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.replacementAXMessagingTimeout)
        func attribute(_ name: String) -> AnyObject? {
            guard budget.take() else { return nil }
            let error: AXError
            var value: AnyObject?
            if let attributeRead { (error, value) = attributeRead(name) }
            else { error = AXUIElementCopyAttributeValue(element, name as CFString, &value) }
            diagnostics.record(name, error: error)
            return error == .success ? value : nil
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
        diagnostics.nodes += 1
        let role = string(attribute(kAXRoleAttribute as String))
        if let role { diagnostics.roles[role, default: 0] += 1 }
        let textValue = attribute(kAXSelectedTextAttribute as String)
        let selectedText = string(textValue)
        if textValue != nil, selectedText == nil { diagnostics.invalidValues += 1 }
        if selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            diagnostics.emptySelections += 1
        }
        func observedRange(_ value: AnyObject?) -> CFRange? {
            guard let value else { return nil }
            guard let result = range(value), result.location >= 0, result.length >= 0,
                  result.location <= Int.max - result.length else {
                diagnostics.invalidValues += 1
                return nil
            }
            if result.length > 0 { diagnostics.positiveRanges += 1 }
            else { diagnostics.emptySelections += 1 }
            return result
        }
        let selectedRange = observedRange(attribute(kAXSelectedTextRangeAttribute as String))
        return ReadOnlySelection.text(
            selectedText: {
                guard selectedText != nil else { return nil }
                let value = string(attribute(kAXValueAttribute as String))
                let placeholder = string(attribute(kAXPlaceholderValueAttribute as String))
                let title = string(attribute(kAXTitleAttribute as String))
                guard budget.take() else { return nil }
                return Self.validSelectionText(
                    selectedText: selectedText, selectedRange: selectedRange,
                    value: value, placeholder: placeholder, title: title, role: role
                )
            },
            ranges: {
                if let selectedRange, selectedRange.length > 0 { return [selectedRange] }
                guard let value = attribute(kAXSelectedTextRangesAttribute as String) else { return [] }
                guard let values = value as? [AnyObject], values.count <= 16 else {
                    diagnostics.invalidValues += 1
                    return []
                }
                if values.isEmpty { diagnostics.emptySelections += 1 }
                let ranges = values.compactMap(observedRange)
                return ranges.count == values.count ? ranges : []
            },
            stringForRange: { selectedRange in
                guard budget.take() else { return nil }
                if let parameterizedText { return parameterizedText(selectedRange) }
                var selectedRange = selectedRange
                guard let parameter = AXValueCreate(.cfRange, &selectedRange) else { return nil }
                var value: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
                )
                diagnostics.record(kAXStringForRangeParameterizedAttribute, error: error)
                return error == .success ? value as? String : nil
            },
            value: { string(attribute(kAXValueAttribute as String)) }
        )
    }
}
