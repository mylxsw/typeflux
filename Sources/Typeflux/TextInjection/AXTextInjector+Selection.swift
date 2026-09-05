import AppKit
import ApplicationServices
import Foundation
import SQLite3

// swiftlint:disable file_length function_body_length
extension AXTextInjector {
    func focusResolutionCandidate(for element: AXUIElement) -> FocusResolutionCandidate {
        FocusResolutionCandidate(
            role: copyStringAttribute(kAXRoleAttribute as String, from: element),
            isEditable: isLikelyEditable(element: element),
            isFocused: copyBooleanAttribute(kAXFocusedAttribute as String, from: element),
            selectedRange: copySelectedTextRange(from: element)
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
                maxChildren: maxChildren
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
        depthRemaining: Int
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
        NetworkDebugLogger.logMessage(
            """
            [Focus Resolution] \(context)
            root: \(elementSummary(rootElement))
            resolved: \(resolvedSummary)
            """
        )
    }

    func focusedElement() -> AXUIElement? {
        if let processID = frontmostProcessID(),
           let focused = focusedElement(for: processID) {
            return focused
        }

        return systemFocusedElement()
    }

    func readSelectedText(
        processID: pid_t?,
        processName: String?
    ) -> (text: String, context: SelectionContext)? {
        guard let processID else {
            return nil
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, Self.replacementAXMessagingTimeout)
        guard let element = deliveryFocusedElement(for: processID) else {
            return nil
        }

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let range = copySelectedTextRange(from: element)
        guard let text = Self.validSelectionText(
            selectedText: copyTextAttribute(kAXSelectedTextAttribute as String, from: element),
            selectedRange: range,
            value: copyTextAttribute(kAXValueAttribute as String, from: element),
            placeholder: copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element),
            title: copyTextAttribute(kAXTitleAttribute as String, from: element),
            role: role
        ) else { return nil }

        let focusedWindow = focusedWindowElement(for: processID)
        let selectionWindow = containingWindow(of: element)
        let windowMatches = focusedWindow.map { window in
            selectionWindow.map { selection in windowsMatch(window, selection) } ?? true
        } ?? true
        let isFocusedTarget = frontmostProcessID() == processID && windowMatches

        let context = SelectionContext(
            element: element,
            windowElement: selectionWindow ?? focusedWindow,
            range: range,
            processID: processID,
            processName: processName,
            selectedText: text,
            role: role,
            subrole: copyStringAttribute(kAXSubroleAttribute as String, from: element),
            identifier: copyStringAttribute(kAXIdentifierAttribute as String, from: element),
            position: copyCGPointAttribute(kAXPositionAttribute as String, from: element),
            size: copyCGSizeAttribute(kAXSizeAttribute as String, from: element),
            windowPosition: (selectionWindow ?? focusedWindow).flatMap {
                copyCGPointAttribute(kAXPositionAttribute as String, from: $0)
            },
            windowSize: (selectionWindow ?? focusedWindow).flatMap {
                copyCGSizeAttribute(kAXSizeAttribute as String, from: $0)
            },
            windowTitle: selectionWindow.flatMap(windowTitle(of:)),
            isFocusedTarget: isFocusedTarget,
            source: "accessibility",
            capturedAt: Date()
        )

        return (text, context)
    }

    /// Web accessibility bridges can expose a stale collapsed range while still
    /// returning the real DOM selection. Non-empty selected text is therefore
    /// positive context evidence; the range only controls replacement safety.
    static func validSelectionText(
        selectedText: String?,
        selectedRange: CFRange?,
        value: String?,
        placeholder: String?,
        title: String?,
        role: String?
    ) -> String? {
        guard let selectedText else { return nil }
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedPlaceholder = placeholder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPlaceholder != trimmed, normalizedTitle != trimmed else { return nil }

        let lacksPositiveRange = selectedRange?.length ?? 0 <= 0
        let isOpaqueContainer = role == "AXWebArea" || role == "AXGroup" || role == "AXUnknown"
        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if lacksPositiveRange, isOpaqueContainer, normalizedValue == trimmed {
            // Several web containers expose their full value through AXSelectedText
            // even with a collapsed caret. Do not treat that as a real selection.
            return nil
        }
        return selectedText
    }

    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, Self.replacementAXMessagingTimeout)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    func processID(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return processID
    }

    func focusedElementMatches(_ expected: AXUIElement?) -> Bool {
        guard let expected else { return true }
        guard let current = focusedElement() else { return false }
        return CFEqual(expected, current)
    }

    func isLikelyEditable(element: AXUIElement) -> Bool {
        targetCapability(element: element) == .writable
    }

    func targetCapability(element: AXUIElement) -> TextTargetCapability {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let selectedRange = copySelectedTextRange(from: element)
        let hasSettableTextAttributes =
            isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
                || isAttributeSettable(kAXValueAttribute as CFString, on: element)
                || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        return Self.targetCapability(
            role: role,
            hasSelectedRange: selectedRange != nil,
            hasSettableTextAttributes: hasSettableTextAttributes
        )
    }

    func systemFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.replacementAXMessagingTimeout)
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: system),
           let resolved = resolveFocusedElement(focused) {
            logFocusResolution(
                context: "systemFocusedElement",
                rootElement: focused,
                resolvedElement: resolved
            )
            return resolved
        }

        return nil
    }

    func focusedElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, Self.replacementAXMessagingTimeout)

        return resolvedFocusedElement(application: appElement)
    }

    func resolvedFocusedElement(application: AXUIElement) -> AXUIElement? {
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: application),
           let resolved = resolveFocusedElement(focused) {
            logFocusResolution(
                context: "focusedElement(appFocusedUIElement)",
                rootElement: focused,
                resolvedElement: resolved
            )
            return resolved
        }

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as String, from: application),
           let resolved = resolveFocusedElement(focusedWindow) {
            logFocusResolution(
                context: "focusedElement(focusedWindow)",
                rootElement: focusedWindow,
                resolvedElement: resolved
            )
            return resolved
        }

        return nil
    }

    func focusedWindowElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, Self.replacementAXMessagingTimeout)
        return copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement)
    }

    func focusedWindowTitle(for processID: pid_t?) -> String? {
        guard let processID, let window = focusedWindowElement(for: processID) else { return nil }
        return windowTitle(of: window)
    }

    func documentURL(for element: AXUIElement, processID: pid_t?) -> URL? {
        if let url = copyDocumentURL(from: element) {
            return url
        }
        if let window = containingWindow(of: element),
           let url = copyDocumentURL(from: window) {
            return url
        }
        if let processID,
           let window = focusedWindowElement(for: processID),
           let url = copyDocumentURL(from: window) {
            return url
        }
        return nil
    }

    func copyDocumentURL(from element: AXUIElement) -> URL? {
        let attributeNames = [
            kAXDocumentAttribute as String,
            "AXURL"
        ]

        for attributeName in attributeNames {
            guard let raw = copyTextAttribute(attributeName, from: element) else {
                continue
            }
            if let url = Self.documentURL(fromAXAttributeValue: raw) {
                return url
            }
        }

        return nil
    }

    static func documentURL(fromAXAttributeValue rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        return nil
    }

    func readDocumentContextText(from url: URL) -> String? {
        guard url.isFileURL else { return nil }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue > Self.documentContextMaxBytes {
                NetworkDebugLogger.logMessage(
                    "[InputContext] document context skipped; file too large: \(url.path)"
                )
                return nil
            }

            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            NetworkDebugLogger.logMessage(
                "[InputContext] document context read failed: \(url.path) | \(error.localizedDescription)"
            )
            return nil
        }
    }

    func visibleTextContext(for element: AXUIElement, processID: pid_t?) -> String? {
        let root = containingWindow(of: element)
            ?? processID.flatMap(focusedWindowElement(for:))
            ?? element
        var remainingNodes = Self.visibleTextContextMaxNodes
        let candidates = collectVisibleTextCandidates(
            in: root,
            depthRemaining: Self.visibleTextContextSearchDepth,
            remainingNodes: &remainingNodes
        )
        return Self.joinedVisibleTextCandidates(candidates)
    }

    func collectVisibleTextCandidates(
        in element: AXUIElement,
        depthRemaining: Int,
        remainingNodes: inout Int
    ) -> [String] {
        guard depthRemaining >= 0, remainingNodes > 0 else { return [] }
        remainingNodes -= 1

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        var candidates: [String] = []
        for attribute in Self.visibleTextCandidateAttributes(for: role) {
            if let text = copyTextAttribute(attribute, from: element),
               Self.isUsefulVisibleTextCandidate(role: role, text: text) {
                candidates.append(text)
                break
            }
        }

        guard depthRemaining > 0 else { return candidates }
        for child in copyElementArrayAttribute(kAXChildrenAttribute as String, from: element) {
            candidates.append(
                contentsOf: collectVisibleTextCandidates(
                    in: child,
                    depthRemaining: depthRemaining - 1,
                    remainingNodes: &remainingNodes
                )
            )
            guard remainingNodes > 0 else { break }
        }

        return candidates
    }

    static func visibleTextCandidateAttributes(for role: String?) -> [String] {
        switch role {
        case "AXStaticText":
            [kAXValueAttribute as String, kAXDescriptionAttribute as String, kAXTitleAttribute as String]
        case "AXTextArea", "AXTextField", "AXGroup", "AXWebArea", "AXUnknown":
            [kAXValueAttribute as String]
        default:
            []
        }
    }

    static func isUsefulVisibleTextCandidate(role: String?, text: String) -> Bool {
        guard visibleTextCandidateAttributes(for: role).isEmpty == false else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard trimmed != "nil" else { return false }
        return true
    }

    static func joinedVisibleTextCandidates(_ candidates: [String]) -> String? {
        var lines: [String] = []
        var previous: String?
        var characterCount = 0
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != previous else { continue }
            let projectedCount = characterCount + trimmed.count + (lines.isEmpty ? 0 : 1)
            guard projectedCount <= visibleTextContextMaxCharacters else {
                NetworkDebugLogger.logMessage(
                    "[InputContext] visible text context truncated at \(characterCount) characters"
                )
                break
            }
            lines.append(trimmed)
            characterCount = projectedCount
            previous = trimmed
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    func applicationStateContext(
        bundleIdentifier: String?,
        selectedText: String?,
        windowTitle: String?
    ) -> ApplicationStateContext? {
        lastApplicationStateFailureReason = nil

        switch bundleIdentifier {
        case "com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2":
            return sublimeSessionContext(
                selectedText: selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                windowTitle: windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "dev.zed.Zed":
            return zedEditorContext(
                selectedText: selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                windowTitle: windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        default:
            return browserDOMContext(bundleIdentifier: bundleIdentifier)
        }
    }

    func browserDOMContext(bundleIdentifier: String?) -> ApplicationStateContext? {
        guard let kind = Self.browserAutomationKind(for: bundleIdentifier) else { return nil }
        let script = Self.browserDOMContextAppleScript(
            bundleIdentifier: kind.bundleIdentifier,
            javascript: Self.browserDOMContextJavaScript,
            command: kind.command
        )

        guard let output = executeAppleScript(script) else {
            return nil
        }

        let payload = Self.browserDOMContextPayload(fromJSON: output)
        guard let payload, let context = Self.browserDOMContext(from: payload) else {
            lastApplicationStateFailureReason = payload?.reason.map { "browser-dom-\($0)" }
                ?? "browser-dom-invalid-response"
            NetworkDebugLogger.logMessage("[InputContext] browser DOM context invalid response: \(output.prefix(200))")
            return nil
        }

        lastApplicationStateFailureReason = nil
        return context
    }

    func executeAppleScript(_ source: String) -> String? {
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo),
              errorInfo == nil
        else {
            if let errorInfo {
                lastApplicationStateFailureReason = Self.appleScriptFailureReason(from: errorInfo)
                NetworkDebugLogger.logMessage("[InputContext] browser DOM context failed: \(errorInfo)")
            }
            return nil
        }

        let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    static func appleScriptFailureReason(from errorInfo: NSDictionary) -> String {
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
        let number = errorInfo[NSAppleScript.errorNumber] as? NSNumber

        if number?.intValue == 12,
           message.localizedCaseInsensitiveContains("JavaScript through AppleScript is turned off") {
            return "browser-dom-javascript-from-apple-events-disabled"
        }

        if number?.intValue == -1743 {
            return "browser-dom-automation-permission-denied"
        }

        return "browser-dom-applescript-failed"
    }

    struct BrowserAutomationKind: Equatable {
        enum Command: Equatable {
            case chromium
            case safari
        }

        let bundleIdentifier: String
        let command: Command
    }

    static func browserAutomationKind(for bundleIdentifier: String?) -> BrowserAutomationKind? {
        guard let bundleIdentifier else { return nil }
        switch bundleIdentifier {
        case "com.google.Chrome",
             "com.google.Chrome.beta",
             "com.google.Chrome.dev",
             "com.google.Chrome.canary",
             "org.chromium.Chromium",
             "com.microsoft.edgemac",
             "com.microsoft.edgemac.Canary",
             "com.brave.Browser",
             "com.vivaldi.Vivaldi",
             "com.operasoftware.Opera",
             "company.thebrowser.Browser":
            return BrowserAutomationKind(bundleIdentifier: bundleIdentifier, command: .chromium)
        case "com.apple.Safari",
             "com.apple.SafariTechnologyPreview":
            return BrowserAutomationKind(bundleIdentifier: bundleIdentifier, command: .safari)
        default:
            return nil
        }
    }

    static func shouldPreferApplicationStateContextBeforeAXValue(
        bundleIdentifier: String?,
        role: String?,
        isFocusedTarget: Bool
    ) -> Bool {
        guard browserAutomationKind(for: bundleIdentifier) != nil else { return false }

        if isFocusedTarget == false {
            return true
        }

        return role == "AXTextField"
    }

    static func shouldSuppressAXValueContext(
        bundleIdentifier: String?,
        role: String?,
        isFocusedTarget: Bool
    ) -> Bool {
        browserAutomationKind(for: bundleIdentifier) != nil
            && role == "AXTextField"
            && isFocusedTarget == false
    }

    static func browserDOMContextAppleScript(
        bundleIdentifier: String,
        javascript: String,
        command: BrowserAutomationKind.Command
    ) -> String {
        let quotedBundle = appleScriptQuotedString(bundleIdentifier)
        let quotedJavaScript = appleScriptQuotedString(javascript)

        switch command {
        case .chromium:
            return """
            tell application id \(quotedBundle)
                if not (exists front window) then return ""
                return execute active tab of front window javascript \(quotedJavaScript)
            end tell
            """
        case .safari:
            return """
            tell application id \(quotedBundle)
                if not (exists front document) then return ""
                return do JavaScript \(quotedJavaScript) in front document
            end tell
            """
        }
    }

    static func appleScriptQuotedString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func browserDOMContext(fromJSON json: String) -> ApplicationStateContext? {
        guard let payload = browserDOMContextPayload(fromJSON: json) else {
            return nil
        }

        return browserDOMContext(from: payload)
    }

    static func browserDOMContextPayload(fromJSON json: String) -> BrowserDOMContextPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrowserDOMContextPayload.self, from: data)
        else {
            return nil
        }

        return payload
    }

    static func browserDOMContext(from payload: BrowserDOMContextPayload) -> ApplicationStateContext? {
        guard payload.ok, payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let start = max(0, min(payload.selectionStart, payload.text.utf16.count))
        let end = max(0, min(payload.selectionEnd, payload.text.utf16.count))
        return ApplicationStateContext(
            text: payload.text,
            selectedRange: CFRange(location: min(start, end), length: abs(end - start))
        )
    }

    struct BrowserDOMContextPayload: Decodable {
        let ok: Bool
        let reason: String?
        let text: String
        let selectionStart: Int
        let selectionEnd: Int
    }

    static let browserDOMContextJavaScript = """
    (function () {
      function json(payload) {
        return JSON.stringify(payload);
      }

      function empty(reason) {
        return json({ ok: false, reason: reason, text: "", selectionStart: 0, selectionEnd: 0 });
      }

      function inputSupportsTextSelection(element) {
        if (!element || element.tagName !== "INPUT") return false;
        return /^(text|search|url|tel|email|password|number)$/i.test(element.type || "text");
      }

      function textNodeOffset(root, targetNode, targetOffset) {
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        var offset = 0;
        var node;
        while ((node = walker.nextNode())) {
          if (node === targetNode) return offset + targetOffset;
          offset += node.nodeValue.length;
        }
        if (targetNode === root) return Math.min(targetOffset, offset);
        return offset;
      }

      function editableRootForSelection(selection) {
        if (!selection || selection.rangeCount === 0) return null;
        var node = selection.anchorNode;
        var element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
        if (!element) return null;
        return element.closest('[contenteditable=""],[contenteditable="true"],[contenteditable="plaintext-only"]');
      }

      var active = document.activeElement;
      if (active && active.tagName === "TEXTAREA") {
        return json({
          ok: true,
          kind: "textarea",
          text: active.value || "",
          selectionStart: active.selectionStart || 0,
          selectionEnd: active.selectionEnd || 0
        });
      }

      if (inputSupportsTextSelection(active)) {
        return json({
          ok: true,
          kind: "input",
          text: active.value || "",
          selectionStart: active.selectionStart || 0,
          selectionEnd: active.selectionEnd || 0
        });
      }

      var selection = window.getSelection();
      var root = active && active.isContentEditable ? active : editableRootForSelection(selection);
      if (!root) return empty("no-editable-root");
      var text = root.innerText || root.textContent || "";
      var start = 0;
      var end = 0;

      if (selection && selection.rangeCount > 0 && root.contains(selection.anchorNode) && root.contains(selection.focusNode)) {
        start = textNodeOffset(root, selection.anchorNode, selection.anchorOffset);
        end = textNodeOffset(root, selection.focusNode, selection.focusOffset);
      }

      return json({
        ok: true,
        kind: "contenteditable",
        text: text,
        selectionStart: Math.min(start, end),
        selectionEnd: Math.max(start, end)
      });
    })();
    """

    func zedEditorContext(selectedText: String?, windowTitle: String?) -> ApplicationStateContext? {
        let dbURLs = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Zed/db/0-stable/db.sqlite")
        ]

        for dbURL in dbURLs {
            guard let context = zedEditorContext(
                dbURL: dbURL,
                selectedText: selectedText,
                windowTitle: windowTitle
            ) else {
                continue
            }
            return context
        }

        return nil
    }

    func zedEditorContext(
        dbURL: URL,
        selectedText: String?,
        windowTitle: String?
    ) -> ApplicationStateContext? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT e.contents, e.buffer_path, s.start, s.end
        FROM editors e
        JOIN items i ON i.item_id = e.item_id AND i.workspace_id = e.workspace_id
        JOIN panes p ON p.pane_id = i.pane_id AND p.workspace_id = i.workspace_id
        LEFT JOIN editor_selections s ON s.item_id = e.item_id AND s.workspace_id = e.workspace_id
        WHERE i.active = 1 AND p.active = 1
        ORDER BY e.item_id DESC
        LIMIT 20;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let contents = Self.sqliteString(statement, column: 0)
            let bufferPath = Self.sqliteString(statement, column: 1)
            let range = Self.sqliteRange(statement, startColumn: 2, endColumn: 3)
            guard let context = zedEditorContext(
                contents: contents,
                bufferPath: bufferPath,
                selectedRange: range,
                selectedText: selectedText,
                windowTitle: windowTitle
            ) else {
                continue
            }
            return context
        }

        return nil
    }

    func zedEditorContext(
        contents: String?,
        bufferPath: String?,
        selectedRange: CFRange?,
        selectedText: String?,
        windowTitle: String?
    ) -> ApplicationStateContext? {
        let text = contents?.isEmpty == false
            ? contents
            : bufferPath.flatMap { readDocumentContextText(from: URL(fileURLWithPath: $0)) }
        guard let text, !text.isEmpty else { return nil }

        if let selectedText, !selectedText.isEmpty,
           Self.sessionContents(text, containsSelection: selectedText) {
            return ApplicationStateContext(text: text, selectedRange: selectedRange)
        }

        if let windowTitle,
           let bufferPath,
           Self.zedWindowTitle(windowTitle, matchesPath: bufferPath) {
            return ApplicationStateContext(text: text, selectedRange: selectedRange)
        }

        return nil
    }

    private static func sqliteString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
    }

    private static func sqliteRange(_ statement: OpaquePointer, startColumn: Int32, endColumn: Int32) -> CFRange? {
        guard sqlite3_column_type(statement, startColumn) != SQLITE_NULL,
              sqlite3_column_type(statement, endColumn) != SQLITE_NULL
        else {
            return nil
        }

        let start = Int(sqlite3_column_int64(statement, startColumn))
        let end = Int(sqlite3_column_int64(statement, endColumn))
        return CFRange(location: min(start, end), length: abs(end - start))
    }

    private static func zedWindowTitle(_ windowTitle: String, matchesPath bufferPath: String) -> Bool {
        let filename = URL(fileURLWithPath: bufferPath).lastPathComponent
        guard !filename.isEmpty else { return false }
        return normalizedSessionSearchText(windowTitle).contains(normalizedSessionSearchText(filename))
    }

    func sublimeSessionContext(selectedText: String?, windowTitle: String?) -> ApplicationStateContext? {
        let localDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sublime Text/Local", isDirectory: true)
        let sessionURLs = [
            localDirectory.appendingPathComponent("Auto Save Session.sublime_session"),
            localDirectory.appendingPathComponent("Session.sublime_session")
        ]

        for url in sessionURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard data.count <= Self.applicationStateContextMaxBytes else {
                NetworkDebugLogger.logMessage(
                    "[InputContext] Sublime session context skipped; file too large: \(url.path)"
                )
                continue
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: data),
                let context = Self.firstSublimeSessionContext(
                    selectedText: selectedText,
                    windowTitle: windowTitle,
                    in: object
                )
            else {
                continue
            }

            return context
        }

        return nil
    }

    static func firstSublimeSessionContext(
        selectedText: String?,
        windowTitle: String?,
        in object: Any
    ) -> ApplicationStateContext? {
        guard let dictionary = object as? [String: Any],
              let windows = dictionary["windows"] as? [[String: Any]]
        else {
            return firstSessionContents(containing: selectedText ?? "", in: object).map {
                ApplicationStateContext(text: $0, selectedRange: nil)
            }
        }

        let selectedText = selectedText?.isEmpty == false ? selectedText : nil
        let windowTitle = windowTitle?.isEmpty == false ? windowTitle : nil

        for window in windows {
            guard let buffers = window["buffers"] as? [[String: Any]] else { continue }
            let selectedSheets = Self.selectedSublimeSheets(in: window)

            for sheet in selectedSheets {
                guard let bufferIndex = sheet["buffer"] as? Int,
                      bufferIndex >= 0,
                      bufferIndex < buffers.count,
                      let contents = buffers[bufferIndex]["contents"] as? String
                else {
                    continue
                }

                if Self.sublimeBuffer(
                    contents,
                    sheet: sheet,
                    matchesSelectedText: selectedText,
                    windowTitle: windowTitle
                ) {
                    return ApplicationStateContext(
                        text: contents,
                        selectedRange: Self.sublimeSelectedRange(from: sheet)
                    )
                }
            }
        }

        if let selectedText,
           let contents = firstSessionContents(containing: selectedText, in: object) {
            return ApplicationStateContext(text: contents, selectedRange: nil)
        }
        return nil
    }

    private static func selectedSublimeSheets(in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            var sheets: [[String: Any]] = []
            if let sheetArray = dictionary["sheets"] as? [[String: Any]] {
                sheets.append(contentsOf: sheetArray.filter { $0["selected"] as? Bool == true })
            }

            for value in dictionary.values {
                sheets.append(contentsOf: selectedSublimeSheets(in: value))
            }
            return sheets
        }

        if let array = object as? [Any] {
            return array.flatMap(selectedSublimeSheets(in:))
        }

        return []
    }

    private static func sublimeBuffer(
        _ contents: String,
        sheet: [String: Any],
        matchesSelectedText selectedText: String?,
        windowTitle: String?
    ) -> Bool {
        if let selectedText,
           sessionContents(contents, containsSelection: selectedText) {
            return true
        }

        guard let windowTitle else { return false }
        return normalizedSessionSearchText(sublimeSheetAutoName(sheet))
            .contains(normalizedSessionSearchText(windowTitle))
    }

    private static func sublimeSheetAutoName(_ sheet: [String: Any]) -> String {
        guard let settings = sheet["settings"] as? [String: Any],
              let nestedSettings = settings["settings"] as? [String: Any],
              let autoName = nestedSettings["auto_name"] as? String
        else {
            return ""
        }
        return autoName
    }

    private static func sublimeSelectedRange(from sheet: [String: Any]) -> CFRange? {
        guard let settings = sheet["settings"] as? [String: Any],
              let selections = settings["selection"] as? [[Int]],
              let firstSelection = selections.first,
              firstSelection.count >= 2
        else {
            return nil
        }

        let start = firstSelection[0]
        let end = firstSelection[1]
        return CFRange(location: min(start, end), length: abs(end - start))
    }

    static func firstSessionContents(containing selectedText: String, in object: Any) -> String? {
        guard !selectedText.isEmpty else { return nil }

        if let dictionary = object as? [String: Any] {
            if let contents = dictionary["contents"] as? String,
               sessionContents(contents, containsSelection: selectedText) {
                return contents
            }

            for value in dictionary.values {
                if let match = firstSessionContents(containing: selectedText, in: value) {
                    return match
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let match = firstSessionContents(containing: selectedText, in: value) {
                    return match
                }
            }
        }

        return nil
    }

    private static func sessionContents(_ contents: String, containsSelection selectedText: String) -> Bool {
        if contents.contains(selectedText) {
            return true
        }

        let normalizedContents = normalizedSessionSearchText(contents)
        let normalizedSelection = normalizedSessionSearchText(selectedText)
        guard !normalizedContents.isEmpty, !normalizedSelection.isEmpty else { return false }
        if normalizedContents.contains(normalizedSelection) {
            return true
        }

        return normalizedSelectionFragments(normalizedSelection).contains { fragment in
            normalizedContents.contains(fragment)
        }
    }

    private static func normalizedSessionSearchText(_ text: String) -> String {
        var normalized = ""
        for character in text {
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                continue
            }

            switch character {
            case "“", "”", "„", "‟", "＂":
                normalized.append("\"")
            case "‘", "’", "‚", "‛", "＇":
                normalized.append("'")
            default:
                normalized.append(String(character).lowercased())
            }
        }
        return normalized
    }

    private static func normalizedSelectionFragments(_ normalizedSelection: String) -> [String] {
        let minimumLength = 18
        guard normalizedSelection.count >= minimumLength else { return [] }

        let preferredLength = min(48, normalizedSelection.count)
        let characters = Array(normalizedSelection)
        var fragments: [String] = []

        for start in stride(
            from: 0,
            to: max(characters.count - preferredLength + 1, 1),
            by: max(preferredLength / 2, 1)
        ) {
            let end = min(start + preferredLength, characters.count)
            let fragment = String(characters[start ..< end])
            if fragment.count >= minimumLength {
                fragments.append(fragment)
            }
        }

        if characters.count > preferredLength {
            let fragment = String(characters[(characters.count - preferredLength) ..< characters.count])
            fragments.append(fragment)
        }

        return Array(Set(fragments))
    }

    static func contextTextSource(
        documentText: String?,
        applicationStateText: String?,
        visibleText: String?
    ) -> String? {
        if documentText != nil { return "document" }
        if applicationStateText != nil { return "application-state" }
        if visibleText != nil { return "visible-text" }
        return nil
    }

    func resolveFocusedElement(_ element: AXUIElement) -> AXUIElement? {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isContainer = role == "AXWindow"
            || Self.genericEditableRoles.contains(role ?? "")
            || Self.opaqueContainerRoles.contains(role ?? "")

        if !isContainer {
            return element
        }

        if role != "AXWindow", validSelectionText(from: element) != nil {
            return element
        }

        if let nestedFocused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: element),
           nestedFocused != element,
           let resolved = resolveFocusedElement(nestedFocused) {
            return resolved
        }

        if let descendant = findFocusedDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth
        ) {
            return descendant
        }

        if let selectionDescendant = findSelectionDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth
        ) {
            return selectionDescendant
        }

        if let editableDescendant = findBestEditableDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth
        ) {
            let candidate = focusResolutionCandidate(for: editableDescendant)
            NetworkDebugLogger.logMessage(
                """
                [Focus Resolution] no focused descendant found; editable descendant exists
                window: \(elementSummary(element))
                editableDescendant: \(elementSummary(editableDescendant))
                """
            )
            if Self.shouldPreferEditableDescendant(overWindowRole: role, candidate: candidate) {
                NetworkDebugLogger.logMessage(
                    """
                    [Focus Resolution] promoting editable descendant as focused target
                    window: \(elementSummary(element))
                    promotedDescendant: \(elementSummary(editableDescendant))
                    """
                )
                return editableDescendant
            }
        }

        return element
    }

    func validSelectionText(from element: AXUIElement) -> String? {
        guard let selectedText = copyTextAttribute(kAXSelectedTextAttribute as String, from: element) else {
            return nil
        }
        return Self.validSelectionText(
            selectedText: selectedText,
            selectedRange: copySelectedTextRange(from: element),
            value: copyTextAttribute(kAXValueAttribute as String, from: element),
            placeholder: copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element),
            title: copyTextAttribute(kAXTitleAttribute as String, from: element),
            role: copyStringAttribute(kAXRoleAttribute as String, from: element)
        )
    }

    func findSelectionDescendant(in element: AXUIElement, depthRemaining: Int) -> AXUIElement? {
        var remainingNodes = Self.selectionDescendantSearchMaxNodes
        return findSelectionDescendant(
            in: element,
            depthRemaining: depthRemaining,
            remainingNodes: &remainingNodes
        )
    }

    private func findSelectionDescendant(
        in element: AXUIElement,
        depthRemaining: Int,
        remainingNodes: inout Int
    ) -> AXUIElement? {
        guard depthRemaining > 0, remainingNodes > 0 else { return nil }

        for child in copyElementArrayAttribute(kAXChildrenAttribute as String, from: element) {
            guard remainingNodes > 0 else { return nil }
            remainingNodes -= 1
            if validSelectionText(from: child) != nil {
                return child
            }
            if let nested = findSelectionDescendant(
                in: child,
                depthRemaining: depthRemaining - 1,
                remainingNodes: &remainingNodes
            ) {
                return nested
            }
        }
        return nil
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

    func clearLatestSelectionContext(ifMatching context: SelectionContext) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let latest = storedLatestSelectionContext,
              latest.capturedAt == context.capturedAt,
              latest.processID == context.processID,
              CFEqual(latest.element, context.element)
        else {
            return
        }
        storedLatestSelectionContext = nil
    }

    func registerSelectionContext(_ context: SelectionContext) -> UUID {
        let contextID = UUID()
        let expiry = Date().addingTimeInterval(-Self.selectionContextLifetime)
        selectionContextLock.lock()
        selectionContexts = selectionContexts.filter { $0.value.capturedAt >= expiry }
        if selectionContexts.count >= Self.maximumSelectionContextCount,
           let oldestID = selectionContexts.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key {
            selectionContexts.removeValue(forKey: oldestID)
        }
        selectionContexts[contextID] = context
        selectionContextLock.unlock()
        return contextID
    }

    func consumeSelectionContext(id: UUID) -> SelectionContext? {
        selectionContextLock.lock()
        defer { selectionContextLock.unlock() }
        guard let context = selectionContexts.removeValue(forKey: id) else { return nil }
        guard Date().timeIntervalSince(context.capturedAt) <= Self.selectionContextLifetime else {
            return nil
        }
        return context
    }

}

// swiftlint:enable file_length function_body_length
