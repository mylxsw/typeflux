import Foundation

/// UserDefaults posts synchronously, sometimes while its caller holds a lock.
/// Never make that caller wait for the main thread to process the notification.
enum SettingsChangeObserver {
    static func observe(center: NotificationCenter = .default,
                        changed: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in changed() }
        }
    }
}
