import Foundation

/// Shows the clipboard panel for a model; `ClipboardPanelController` is the AppKit implementation.
protocol ClipboardPanelPresenting: AnyObject {
    var isPresented: Bool { get }
    func present(_ model: ClipboardPanelModel)
    func dismiss()
    func toggleQuickLook(urls: [URL])
}
