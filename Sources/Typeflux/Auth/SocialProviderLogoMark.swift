import AppKit
import SwiftUI

struct SocialProviderLogoMark: View {
    let resourceName: String
    var isTemplate = false

    var body: some View {
        if let image = logoImage {
            Image(nsImage: image)
                .renderingMode(isTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
        }
    }

    private var logoImage: NSImage? {
        guard let url = Bundle.appResources.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "Resources"
        )
            ?? Bundle.appResources.url(forResource: resourceName, withExtension: "svg")
        else {
            return nil
        }

        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        if isTemplate {
            image.isTemplate = true
        }

        return image
    }
}
