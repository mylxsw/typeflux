import Foundation

extension Bundle {
    /// Resource bundle for the Typeflux module.
    ///
    /// SwiftPM's generated `Bundle.module` accessor for executable targets only
    /// checks `Bundle.main.bundleURL` (which resolves to the `.app` root) and a
    /// hard-coded developer-machine `.build` path. Neither exists in a
    /// codesigned `.app` installed on an end user's machine, where resources
    /// must live under `Contents/Resources/`. This accessor searches the
    /// standard `.app` resource location first and falls back to
    /// `Bundle.module` so dev builds keep working.
    static let appResources: Bundle = {
        let bundleName = "Typeflux_Typeflux.bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(bundleName)
        )
        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .module
    }()
}
