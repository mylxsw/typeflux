import Combine
import Foundation

/// Shared by the native toolbar search and its standalone gallery surface.
@MainActor
public final class TypefluxSearchState: ObservableObject {
    @Published public var query: String {
        didSet {
            if !query.isEmpty {
                isExpanded = true
            }
            if query.isEmpty, !isFocused {
                isExpanded = false
            }
        }
    }

    @Published public private(set) var isExpanded: Bool
    @Published public private(set) var isFocused = false

    public init(query: String = "", expanded: Bool = false) {
        self.query = query
        isExpanded = expanded || !query.isEmpty
    }

    public func expand() {
        isExpanded = true
        isFocused = true
    }

    public func focusChanged(_ focused: Bool) {
        isFocused = focused
        isExpanded = focused || !query.isEmpty
    }

    /// Returns whether this search consumed Escape; an already collapsed search does not.
    @discardableResult public func escape() -> Bool {
        guard isExpanded else { return false }
        if query.isEmpty {
            isFocused = false
            isExpanded = false
        } else {
            query = ""
            isExpanded = true
        }
        return true
    }

    public func clear() {
        expand()
        query = ""
    }
}
