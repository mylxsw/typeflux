import SwiftUI

/// Native examples are interactive; this observer reports the interaction without styling the control.
struct TypefluxControlGallerySection<Content: View>: View {
    let title: String
    let interactive: Bool
    let content: Content
    @State private var hovered = false
    @GestureState private var pressed = false
    @FocusState private var focused: Bool

    init(_ title: String, interactive: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(pressed ? "Pressed" : focused ? "Focus" : hovered ? "Hover" : "Normal")
                    .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            Text("Normal / hover / pressed / focus: interact with the live sample. Disabled sample below.")
                .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            content.focusable(interactive).focused($focused)
                .onHover { hovered = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true },
                                     including: interactive ? .all : .none)
            Divider()
            Text("Disabled").font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            content.disabled(true)
        }.padding(16)
            .background(TypefluxColor.windowBackground.color, in: RoundedRectangle(cornerRadius: 8))
    }
}
