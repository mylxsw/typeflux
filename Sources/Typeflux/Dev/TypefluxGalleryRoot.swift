import SwiftUI

struct TypefluxGalleryRoot: View {
    @ObservedObject var state: TypefluxGalleryState
    var onAppearanceChange: (ColorScheme) -> Void

    var body: some View {
        TypefluxGalleryView(style: $state.style, appearance: $state.appearance,
                            labels: TypefluxGalleryWindowController.labels) {
            TypefluxControlsGalleryView()
            TypefluxNavigationGallery(labels: TypefluxNavigationGalleryExamples.labels,
                                      items: TypefluxNavigationGalleryExamples.items,
                                      modes: TypefluxNavigationGalleryExamples.modes)
        }
            .onChange(of: state.appearance, perform: onAppearanceChange)
    }
}
