import AppKit
import ApplicationServices
import Foundation

// swiftlint:disable file_length function_body_length opening_brace
extension AXTextInjector {
    func focusResolutionCandidate(for element: AXUIElement) -> FocusResolutionCandidate {
        FocusResolutionCandidate(
            role: copyStringAttribute(kAXRoleAttribute as String, from: element),
            isEditable: isLikelyEditable(element: element),
            isFocused: copyBooleanAttribute(kAXFocusedAttribute as String, from: element),
            selectedRange: copySelectedTextRange(from: element),
        )
    }

    func subtreeSummary(of element: AXUIElement, depthRemaining: Int, maxChildren: Int = 8) -> [String] {
        guard depthRemaining >= 0 else { return [] }

        var lines: [String] = [elementSummary(element)]
        guard depthRemaining > 0 else { return lines }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        if children.isEmpty {
            return lines
        }

        for (index, child) in children.prefix(maxChildren).enumerated() {
            let childLines = subtreeSummary(
                of: child,
                depthRemaining: depthRemaining - 1,
                maxChildren: maxChildren,
            )
            lines.append(contentsOf: childLines.map { "child[\(index)] " + $0 })
        }

        if children.count > maxChildren {
            lines.append("child[+] truncated additionalChildren=\(children.count - maxChildren)")
        }

        return lines
    }

    func findBestEditableDescendant(
        in element: AXUIElement,
        depthRemaining: Int,
    ) -> AXUIElement? {
        guard depthRemaining >= 0 else { return nil }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        var bestElement: AXUIElement?
        var bestScore = 0

        for child in children {
            let candidate = focusResolutionCandidate(for: child)
            let score = Self.editableCandidateScore(for: candidate)
            if score > bestScore {
                bestScore = score
                bestElement = child
            }

            guard depthRemaining > 0,
                  let nested = findBestEditableDescendant(in: child, depthRemaining: depthRemaining - 1)
            else {
                continue
            }

            let nestedCandidate = focusResolutionCandidate(for: nested)
            let nestedScore = Self.editableCandidateScore(for: nestedCandidate)
            if nestedScore > bestScore {
                bestScore = nestedScore
                bestElement = nested
            }
        }

        return bestElement
    }

    func logFocusResolution(context: String, rootElement: AXUIElement, resolvedElement: AXUIElement?) {
        let resolvedSummary = resolvedElement.map(elementSummary) ?? "<nil>"
        let editableCandidate = findBestEditableDescendant(
            in: rootElement,
            depthRemaining: Self.focusedDescendantSearchDepth,
        )
        let editableCandidateSummary = editableCandidate.map(elementSummary) ?? "<nil>"
        let tree = subtreeSummary(of: rootElement, depthRemaining: 2).joined(separator: "\n")
        NetworkDebugLogger.logMessage(
            """
            [Focus Resolution] \(context)
            root: \(elementSummary(rootElement))
            resolved: \(resolvedSummary)
            bestEditableDescendant: \(editableCandidateSummary)
            subtree:
            \(tree)
            """,
        )
    }

    func focusedElement() -> AXUIElement? {
        if let processID = frontmostProcessID(),
           let focused = focusedElement(for: processID)
        {
            return focused
        }

        return systemFocusedElement()
    }

    func readSelectedText() -> (text: String, context: SelectionContext)? {
        guard let element = focusedElement() else {
            return nil
        }

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isNativeText = Self.nativeEditableRoles.contains(role ?? "")
        let isSettable = isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)

        if !isNativeText, !isSettable {
            return nil
        }

        let range = copySelectedTextRange(from: element)
        if let range, range.length == 0 {
            return nil
        }

        guard let text = copyStringAttribute(kAXSelectedTextAttribute, from: element) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as String, from: element),
           placeholder == text
        {
            return nil
        }
        if let title = copyStringAttribute(kAXTitleAttribute as String, from: element),
           title == text
        {
            return nil
        }

        if range == nil, role == "AXWebArea" || role == "AXGroup" || role == "AXUnknown",
           let value = copyStringAttribute(kAXValueAttribute as String, from: element),
           value == text
        {
            return nil
        }

        guard let range else { return nil }

        let processID = frontmostProcessID()
        let focusedWindow = processID.flatMap(focusedWindowElement(for:))
        let selectionWindow = containingWindow(of: element)
        let isFocusedTarget = focusedWindow.map { window in
            selectionWindow.map { selection in windowsMatch(window, selection) } ?? true
        } ?? false

        let context = SelectionContext(
            element: element,
            range: range,
            processID: processID,
            processName: frontmostApplicationName(),
            role: role,
            windowTitle: selectionWindow.flatMap(windowTitle(of:)),
            isFocusedTarget: isFocusedTarget,
            source: "accessibility",
            capturedAt: Date(),
        )

        return (text, context)
    }

    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    func isLikelyEditable(element: AXUIElement) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let selectedRange = copySelectedTextRange(from: element)

        if Self.nativeEditableRoles.contains(role ?? "") {
            return true
        }

        if let role, Self.nonEditableFalsePositiveRoles.contains(role) {
            return false
        }

        let hasSettableTextAttributes =
            isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
                || isAttributeSettable(kAXValueAttribute as CFString, on: element)
                || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)

        if Self.genericEditableRoles.contains(role ?? "") {
            return selectedRange != nil || hasSettableTextAttributes
        }

        return selectedRange != nil && hasSettableTextAttributes
    }

    func systemFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: system),
           let resolved = resolveFocusedElement(focused)
        {
            logFocusResolution(
                context: "systemFocusedElement",
                rootElement: focused,
                resolvedElement: resolved,
            )
            return resolved
        }

        return nil
    }

    func focusedElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)

        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focused)
        {
            logFocusResolution(
                context: "focusedElement(appFocusedUIElement)",
                rootElement: focused,
                resolvedElement: resolved,
            )
            return resolved
        }

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focusedWindow)
        {
            logFocusResolution(
                context: "focusedElement(focusedWindow)",
                rootElement: focusedWindow,
                resolvedElement: resolved,
            )
            return resolved
        }

        return nil
    }

    func focusedWindowElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)
        return copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement)
    }

    func focusedWindowTitle(for processID: pid_t?) -> String? {
        guard let processID, let window = focusedWindowElement(for: processID) else { return nil }
        return windowTitle(of: window)
    }

    func resolveFocusedElement(_ element: AXUIElement) -> AXUIElement? {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)

        if role != "AXWindow" {
            return element
        }

        if let nestedFocused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: element),
           nestedFocused != element,
           let resolved = resolveFocusedElement(nestedFocused)
        {
            return resolved
        }

        if let descendant = findFocusedDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth,
        ) {
            return descendant
        }

        if let editableDescendant = findBestEditableDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth,
        ) {
            let candidate = focusResolutionCandidate(for: editableDescendant)
            NetworkDebugLogger.logMessage(
                """
                [Focus Resolution] no focused descendant found; editable descendant exists
                window: \(elementSummary(element))
                editableDescendant: \(elementSummary(editableDescendant))
                """,
            )
            if Self.shouldPreferEditableDescendant(overWindowRole: role, candidate: candidate) {
                NetworkDebugLogger.logMessage(
                    """
                    [Focus Resolution] promoting editable descendant as focused target
                    window: \(elementSummary(element))
                    promotedDescendant: \(elementSummary(editableDescendant))
                    """,
                )
                return editableDescendant
            }
        }

        return element
    }

    func findFocusedDescendant(in element: AXUIElement, depthRemaining: Int) -> AXUIElement? {
        guard depthRemaining > 0 else { return nil }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        for child in children {
            if let focused = copyBooleanAttribute(kAXFocusedAttribute as String, from: child), focused {
                return child
            }
            if let nested = findFocusedDescendant(in: child, depthRemaining: depthRemaining - 1) {
                return nested
            }
        }

        return nil
    }

    func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depthRemaining = Self.focusedDescendantSearchDepth + 10

        while let node = current, depthRemaining > 0 {
            if copyStringAttribute(kAXRoleAttribute as String, from: node) == kAXWindowRole as String {
                return node
            }

            current = copyElementAttribute(kAXParentAttribute as String, from: node)
            depthRemaining -= 1
        }

        return nil
    }

    func containingWindowTitle(of element: AXUIElement) -> String? {
        guard let window = containingWindow(of: element) else { return nil }
        return windowTitle(of: window)
    }

    func windowTitle(of window: AXUIElement) -> String? {
        copyTextAttribute(kAXTitleAttribute as String, from: window)
    }

    func windowsMatch(_ lhs: AXUIElement, _ rhs: AXUIElement?) -> Bool {
        guard let rhs else { return false }
        if CFEqual(lhs, rhs) {
            return true
        }

        let lhsTitle = windowTitle(of: lhs)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTitle = windowTitle(of: rhs)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsTitle, let rhsTitle, !lhsTitle.isEmpty, lhsTitle == rhsTitle {
            return true
        }

        let lhsPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: lhs)
        let rhsPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: rhs)
        let lhsSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: lhs)
        let rhsSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: rhs)

        return lhsPosition == rhsPosition && lhsSize == rhsSize
    }

    func activeSelectionContext() -> SelectionContext? {
        guard let latestSelectionContext else { return nil }
        guard Date().timeIntervalSince(latestSelectionContext.capturedAt) <= Self.selectionContextLifetime else {
            self.latestSelectionContext = nil
            return nil
        }
        return latestSelectionContext
    }

    func restoreSelectionContext(_ context: SelectionContext) {
        let needsReactivation = Self.shouldReactivateProcessForSelectionRestore(
            targetProcessID: context.processID,
            frontmostProcessID: frontmostProcessID(),
        )

        if needsReactivation,
           let processID = context.processID,
           let app = NSRunningApplication(processIdentifier: processID)
        {
            app.activate(options: [.activateIgnoringOtherApps])

            let deadline = Date().addingTimeInterval(0.8)
            var activated = false
            while Date() < deadline {
                usleep(50000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                    activated = true
                    break
                }
            }

            if !activated {
                app.activate(options: [.activateIgnoringOtherApps])
                usleep(Self.focusRestoreDelayMicroseconds)
            }
        }

        _ = setFocused(true, on: context.element)
        if let range = context.range {
            _ = setSelectedTextRange(range, on: context.element)
        }
    }
}

// swiftlint:enable file_length function_body_length opening_brace
