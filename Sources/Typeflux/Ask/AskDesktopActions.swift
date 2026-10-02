import AppKit
import ApplicationServices

/// Pure helpers behind the computer tool: key codes, shortcut parsing and the
/// accessibility snapshot, kept apart from event posting so they can be tested.
enum AskDesktopActions {
    /// ANSI virtual key codes.
    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53, "backspace": 51, "delete": 117,
            "up": 126, "down": 125, "left": 123, "right": 124, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44, "semicolon": 41, "quote": 39,
            "leftbracket": 33, "rightbracket": 30, "backslash": 42, "grave": 50
        ]
        let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
                                               "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
                                               "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        for (letter, code) in letters { map[String(letter)] = code }
        let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() { map[String(digit)] = code }
        map["-"] = 27; map["="] = 24; map[","] = 43; map["."] = 47; map["/"] = 44; map[";"] = 41; map["'"] = 39
        map["["] = 33; map["]"] = 30; map["\\"] = 42; map["`"] = 50
        return map
    }()

    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn
    ]

    /// Parses shortcuts such as "cmd+shift+t" into one key and its modifiers.
    static func parseHotkey(_ text: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, let key = keyCodes[last] else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifierFlags[part] else { return nil }
            flags.insert(flag)
        }
        return (key, flags)
    }

    /// Converts a normalized (0...1) point on a display to global screen coordinates.
    static func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
        return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }

    /// One accessibility element, abstracted for formatting and tests.
    struct Node: Equatable {
        var role: String
        var name: String
        var value: String
        var frame: CGRect?
        var children: [Node] = []
    }

    static let maximumNodes = 300
    static let maximumDepth = 12
    static let interestingRoles: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
                                                "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXTab", "AXCell", "AXRow",
                                                "AXStaticText", "AXImage", "AXSlider", "AXComboBox", "AXSearchField", "AXHeading"]

    /// Renders the tree as indented lines. Element centers are normalized to `display`
    /// so they can be passed to click directly; elements without text are folded.
    static func describe(_ root: Node, display: CGRect) -> String {
        var lines: [String] = []
        var count = 0
        func visit(_ node: Node, depth: Int) {
            guard count < maximumNodes, depth <= maximumDepth else { return }
            let label = [node.name, node.value].filter { !$0.isEmpty }.map { String($0.prefix(80)) }.joined(separator: " = ")
            let shown = depth == 0 || !label.isEmpty || interestingRoles.contains(node.role)
            if shown {
                count += 1
                var line = String(repeating: "  ", count: min(depth, 8)) + node.role.replacingOccurrences(of: "AX", with: "")
                if !label.isEmpty { line += " \"\(label.replacingOccurrences(of: "\n", with: " "))\"" }
                if let frame = node.frame, display.width > 1, display.height > 1, display.intersects(frame) {
                    let x = (frame.midX - display.minX) / (display.width - 1), y = (frame.midY - display.minY) / (display.height - 1)
                    if (0 ... 1).contains(x), (0 ... 1).contains(y) { line += String(format: " @(%.3f, %.3f)", x, y) }
                }
                lines.append(line)
            }
            for child in node.children { visit(child, depth: shown ? depth + 1 : depth) }
        }
        visit(root, depth: 0)
        if count >= maximumNodes { lines.append("[more elements omitted]") }
        return lines.joined(separator: "\n")
    }

    /// Reads the focused window of `pid` (or its first window) from the accessibility API.
    static func snapshot(pid: pid_t) -> Node? {
        let app = AXUIElementCreateApplication(pid)
        var budget = maximumNodes * 4
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ name: String) -> String {
            (attribute(element, name) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            var origin = CGPoint.zero, size = CGSize.zero
            guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
                  AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        func node(_ element: AXUIElement, depth: Int) -> Node {
            budget -= 1
            var value = attribute(element, kAXValueAttribute)
            if !(value is String) { value = nil }
            var result = Node(role: string(element, kAXRoleAttribute), name: [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)].first { !$0.isEmpty } ?? "",
                              value: (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), frame: frame(element))
            if depth < maximumDepth, budget > 0, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                result.children = children.prefix(100).compactMap { budget > 0 ? node($0, depth: depth + 1) : nil }
            }
            return result
        }
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let candidate = focused ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let candidate, CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
        return node(candidate as! AXUIElement, depth: 0)
    }
}
