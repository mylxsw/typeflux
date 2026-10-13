import SwiftUI

public struct TypefluxForm<Content: View>: View {
    private let content: Content
    private let maximumContentHeight: CGFloat?
    @State private var measuredContentHeight: CGFloat?

    public init(maximumContentHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.maximumContentHeight = maximumContentHeight
        self.content = content()
    }

    public var body: some View {
        Group {
            if let maximumContentHeight {
                form
                    .background(TypefluxFormContentHeight(height: $measuredContentHeight).frame(width: 0, height: 0))
                    .frame(minHeight: 0,
                           idealHeight: min(maximumContentHeight, measuredContentHeight ?? maximumContentHeight),
                           maxHeight: min(maximumContentHeight, measuredContentHeight ?? maximumContentHeight))
            } else {
                form
            }
        }
        .frame(maxWidth: 640).frame(maxWidth: .infinity)
    }

    private var form: some View { Form { content }.formStyle(.grouped) }
}
