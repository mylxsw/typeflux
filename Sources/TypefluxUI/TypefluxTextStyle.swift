import SwiftUI

public enum TypefluxTextStyle: String, CaseIterable, Sendable {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote

    public var textStyle: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        }
    }

    public var font: Font {
        .system(textStyle)
    }
}
