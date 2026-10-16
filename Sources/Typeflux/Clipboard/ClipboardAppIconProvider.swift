import Foundation
import TypefluxMediaProtocol

/// Pure descriptors only: discovery and rasterization belong to the media child.
/// The visible row owns its pixels, authorization and cancellation, with no bundle-ID cache.
enum ClipboardAppIconProvider {
    static func target(for entry: ClipboardEntry, ownBundle: Bundle = .main) -> MediaNativeIcon? {
        if entry.kind == .voice {
            // A development app need not be registered with Launch Services yet.
            if ownBundle.bundleURL.pathExtension == "app" {
                return .init(kind: .file, value: ownBundle.bundleURL.path)
            }
            return target(bundleID: "ai.gulu.app.typeflux")
        }
        return target(bundleID: entry.sourceBundleID)
    }

    static func target(bundleID: String?) -> MediaNativeIcon? {
        guard let bundleID else { return nil }
        let target = MediaNativeIcon(kind: .application, value: bundleID)
        return (try? target.validate()) == nil ? nil : target
    }
}
