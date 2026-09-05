import ApplicationServices
import Foundation

/// Bounds both traversal size and elapsed time. Each AX call also has the
/// injector's per-message timeout; a timeout cannot multiply by the whole tree.
struct TextFocusSearchBudget {
    private var remaining: Int
    private let deadline: TimeInterval
    private let now: () -> TimeInterval

    init(nodes: Int = 32, seconds: TimeInterval = 0.5,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        remaining = max(0, nodes)
        self.now = now
        deadline = now() + max(0, seconds)
    }

    mutating func take() -> Bool {
        guard remaining > 0, now() < deadline else { return false }
        remaining -= 1
        return true
    }
}

enum FocusedTextTargetResolver {
    static func resolve<Node>(
        root: Node,
        role: (Node) -> String?,
        nestedFocus: (Node) -> Node?,
        focused: (Node) -> Bool,
        children: (Node) -> [Node],
        matches: (Node, Node) -> Bool,
        budget initialBudget: TextFocusSearchBudget = TextFocusSearchBudget()
    ) -> Node? {
        var budget = initialBudget
        var current = root
        var seen: [Node] = []
        while budget.take() {
            guard !seen.contains(where: { matches($0, current) }) else { return nil }
            seen.append(current)
            let currentRole = role(current)
            if AXTextInjector.nativeEditableRoles.contains(currentRole ?? "") { return current }
            guard budget.take() else { return nil }
            if let nested = nestedFocus(current), !matches(nested, current) {
                current = nested
                continue
            }
            if let currentRole, AXTextInjector.nonEditableFalsePositiveRoles.contains(currentRole),
               !AXTextInjector.opaqueContainerRoles.contains(currentRole) { return current }

            var pending = Array(children(current).prefix(32))
            var index = 0
            while index < pending.count, budget.take() {
                let child = pending[index]
                index += 1
                guard !seen.contains(where: { matches($0, child) }) else { continue }
                seen.append(child)
                if focused(child) { return child }
                guard budget.take() else { break }
                pending.append(contentsOf: children(child).prefix(32))
            }
            // Custom editors can expose only their focused AXWindow. Missing
            // child accessibility is unknown capability, not proof of no input.
            // Preserve that exact target for one guarded paste; never substitute
            // an unfocused child or claim success without edit evidence.
            return current
        }
        return nil
    }
}

extension AXTextInjector {
    /// Never promote an unfocused editable sibling merely because it has a caret.
    func deliveryFocusedElement(for processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        guard let root = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: application) else {
            return nil
        }
        return FocusedTextTargetResolver.resolve(
            root: root,
            role: { copyStringAttribute(kAXRoleAttribute as String, from: $0) },
            nestedFocus: { copyElementAttribute(kAXFocusedUIElementAttribute as String, from: $0) },
            focused: { copyBooleanAttribute(kAXFocusedAttribute as String, from: $0) == true },
            children: { copyElementArrayAttribute(kAXChildrenAttribute as String, from: $0) },
            matches: { CFEqual($0, $1) }
        )
    }
}
