import SwiftUI

public extension View {
    /// Apply the library's native title metadata and action priorities to an app-owned navigation layout.
    func typefluxWindowChrome(title: String, actionTitles: Set<String> = []) -> some View {
        background(TypefluxWindowTitleBridge(title: title, actionTitles: actionTitles).frame(width: 0, height: 0))
    }
}
