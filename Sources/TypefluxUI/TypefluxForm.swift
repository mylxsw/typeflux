import SwiftUI

public struct TypefluxForm<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        Form { content }.formStyle(.grouped).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }
}
