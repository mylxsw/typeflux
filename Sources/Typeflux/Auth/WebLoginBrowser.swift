import AppKit

/// Open the default browser directly. The application URL router receives the callback.
@MainActor
final class WebLoginBrowser: WebLoginBrowserSession {
    private let url: URL
    private let open: (URL) -> Bool

    init(url: URL, scheme _: String, completion _: @escaping (URL?, Bool) -> Void,
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.url = url
        self.open = open
    }

    func start() -> Bool { open(url) }

    // A browser tab belongs to the user. Cancelling clears the coordinator's transaction.
    func cancel() {}
}
