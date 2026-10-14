import SwiftUI

/// Measures natural content, including the rows inside the constrained scroll viewport.
struct AskTranslationContentHeight: PreferenceKey {
    enum Part: Hashable {
        case title, original, languages, results, notice, footer
    }

    static let defaultValue: [Part: CGFloat] = [:]

    static func reduce(value: inout [Part: CGFloat], nextValue: () -> [Part: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func translationContentHeight(_ part: AskTranslationContentHeight.Part, enabled: Bool = true) -> some View {
        background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key: AskTranslationContentHeight.self, value: [part: geometry.size.height])
                }
            }
        }
    }
}
