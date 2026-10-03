import AppKit
import WebKit

struct AskProjectPreviewEvidence: Codable {
    var pageText: String
    var console: [String]
    var errors: [String]
    var screenshotHash: String
    var artifacts: [AskArtifactRef]
}

@MainActor enum AskProjectPreviewCapture {
    /// Captures actual WebKit pixels and DOM. Page console instrumentation is
    /// observational only; a hostile page can tamper with its own console hooks.
    static func capture(_ preview: AskDevelopmentPreview, store: AskArtifactStore,
                        authorize: () throws -> Void) async throws -> AskProjectPreviewEvidence {
        let host = AskPreviewHost()
        defer { host.close(); preview.close() }
        let view = try await host.open(.developmentService(process: preview.lease.reference, address: preview.address),
                                       enabled: true, development: preview) { _ in throw AskArtifactError.denied }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        try await waitUntilLoaded(host)
        try authorize(); try preview.validate()
        let page = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        let diagnostics = try await host.collectDiagnostics()
        guard diagnostics.errors.isEmpty else { throw AskArtifactError.unavailable }
        let image = try await view.takeSnapshot(configuration: nil)
        guard let png = AskArtifactActions.pngData(image), !png.isEmpty else { throw AskArtifactError.unavailable }
        let finalDiagnostics = try await host.collectDiagnostics()
        guard finalDiagnostics.errors.isEmpty else { throw AskArtifactError.unavailable }
        try Task.checkCancellation(); try authorize(); try preview.validate()
        var evidence = AskProjectPreviewEvidence(
            pageText: String(page.prefix(16000)),
            console: finalDiagnostics.console,
            errors: finalDiagnostics.errors,
            screenshotHash: AskToolPolicy.digest(png),
            artifacts: []
        )
        // Only host-observed bytes are published here. Source HTML/resources are
        // captured separately by the version-validated D03 artifact tool.
        let log = try AskLocalTools.terminalEncoder.encode(evidence)
        let screenshot = try store.publish(files: ["preview.png": png], entry: "preview.png", scope: preview.scope)
        let summary = try store.publish(files: ["preview.json": log], entry: "preview.json", scope: preview.scope)
        evidence.artifacts = [screenshot, summary]
        return evidence
    }

    static func waitUntilLoaded(_ host: AskPreviewHost) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard let view = host.webView else { throw AskArtifactError.unavailable }
            if view.url?.scheme == AskPreviewPolicy.scheme, !view.isLoading,
               await (try? view.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AskArtifactError.unavailable
    }
}
