import SwiftUI

struct ModelIconTile<Content: View>: View {
    var size: CGFloat = 34
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(
                StudioTheme.iconTileSurface,
                in: RoundedRectangle(
                    cornerRadius: TypefluxRadius.navigationIcon.value(for: .classic),
                    style: .continuous
                )
            )
    }
}
