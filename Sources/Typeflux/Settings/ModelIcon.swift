import SwiftUI
import TypefluxChat

/// The model's family is independent of the endpoint that hosts it.
@MainActor
struct ModelIcon: View {
    let model: RegisteredModel
    var provider: RegisteredProvider?
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    private static let images = NSCache<NSString, NSImage>()

    var descriptor: ModelIconDescriptor {
        ModelIconResolver.resolve(modelID: model.id, displayName: model.name,
                                  providerID: provider?.remote?.rawValue ?? provider?.id)
    }

    static func image(for descriptor: ModelIconDescriptor, dark: Bool) -> NSImage? {
        guard let url = descriptor.resourceURL(dark: dark) else { return nil }
        let key = url.path as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    var body: some View {
        let descriptor = descriptor
        Group {
            if let image = Self.image(for: descriptor, dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .renderingMode(descriptor.isMonochrome ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
            } else if descriptor != .generic, let provider {
                ModelProviderIcon(provider: provider.studioProviderID, size: size)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: size * 0.75, weight: .regular))
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
