import SwiftUI

public struct TypefluxEmptyState<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: String
    private let actions: Actions

    public init(_ title: String, systemImage: String, description: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    @ViewBuilder public var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: { actions }
        } else {
            TypefluxEmptyStateFallback(title: title, systemImage: systemImage,
                                      description: description, actions: actions)
        }
    }
}

extension TypefluxEmptyState where Actions == EmptyView {
    public init(_ title: String, systemImage: String, description: String) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
