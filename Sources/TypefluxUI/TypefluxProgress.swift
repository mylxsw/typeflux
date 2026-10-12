import SwiftUI

public struct TypefluxProgress: View {
    private let title: String
    private let progress: TypefluxProgressValue

    public init(_ title: String, value: Double? = nil, total: Double = 1) {
        self.title = title
        progress = TypefluxProgressValue(value: value, total: total)
    }

    public var body: some View {
        ProgressView(title, value: progress.value, total: progress.total).accessibilityLabel(Text(title))
    }
}
