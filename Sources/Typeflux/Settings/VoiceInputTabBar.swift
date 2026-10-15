import SwiftUI

/// The Voice Input pages' tabs (overview, vocabulary, personas), with item counts.
struct VoiceInputTabBar: View {
    let selection: StudioSection
    /// The count shown beside a tab, if it has one.
    var count: (StudioSection) -> Int? = { _ in nil }
    let onSelect: (StudioSection) -> Void

    var body: some View {
        TFTabBar(options: StudioSection.voiceInputCases.map { TFOption($0, $0.title, count: count($0)) },
                 selection: Binding(get: { selection }, set: onSelect),
                 identifier: { "studio.voiceInput.tab.\($0.rawValue)" })
    }
}
