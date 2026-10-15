import SwiftUI

/// Tabs that switch between the Models page's tabs; they look like the Voice Input tabs.
struct ModelPageTabBar: View {
    let selection: ModelPageTab
    let onSelect: (ModelPageTab) -> Void

    var body: some View {
        TFTabBar(options: ModelPageTab.allCases.map { TFOption($0, $0.title) },
                 selection: Binding(get: { selection }, set: onSelect),
                 identifier: { "studio.models.tab.\($0.rawValue)" })
    }
}
