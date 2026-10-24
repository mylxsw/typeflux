import AppKit
import Quartz
import SwiftUI

/// Formats the side panel cannot render itself (Office, iWork, rich text, media) show a
/// read-only Quick Look preview, the one Finder shows on Space.
enum AskSidePanelQuickLook {
    static let extensions: Set<String> = [
        "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlsm", "ppt", "pptx", "pps", "ppsx",
        "pages", "numbers", "key", "rtf", "rtfd", "odt", "ods", "odp", "epub",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "mp4", "m4v", "mov",
        "usdz", "ttf", "otf"
    ]

    static func previews(_ fileExtension: String) -> Bool {
        extensions.contains(fileExtension.lowercased())
    }
}

/// A Quick Look preview of a file the access check admitted. The view is torn down with the
/// tab, which closes the preview.
struct AskSidePanelQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context _: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator _: ()) {
        view.close()
    }
}
