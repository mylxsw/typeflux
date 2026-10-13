import AppKit
import SwiftUI

/// Shares the owned, window-scoped keyboard dispatcher with custom app navigation.
public struct TypefluxWindowKeyHandler: View {
    private let handle: (NSEvent) -> Bool

    public init(handle: @escaping (NSEvent) -> Bool) {
        self.handle = handle
    }

    public var body: some View {
        TypefluxKeyboardMonitor(handle: handle).frame(width: 0, height: 0)
    }
}
