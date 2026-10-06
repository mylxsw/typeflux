import Foundation
import UserNotifications

protocol LocalNotificationSending: Sendable {
    func sendLocalNotification(title: String, body: String, identifier: String) async
}

struct NoopLocalNotificationService: LocalNotificationSending {
    func sendLocalNotification(title _: String, body _: String, identifier _: String) async {}
}

final class SystemLocalNotificationService: NSObject, LocalNotificationSending, UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    static let shared = SystemLocalNotificationService()

    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
    }

    func sendLocalNotification(title: String, body: String, identifier: String) async {
        _ = await deliverLocalNotification(title: title, body: body, identifier: identifier)
    }

    /// Sends a notification, asking for permission the first time. False when
    /// notifications are not allowed or the system did not take it.
    func deliverLocalNotification(title: String, body: String, identifier: String) async -> Bool {
        do {
            let granted = try await requestAuthorizationIfNeeded()
            guard granted else { return false }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try await add(request)
            return true
        } catch {
            NetworkDebugLogger.logError(context: "Local notification failed", error: error)
            return false
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func requestAuthorizationIfNeeded() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notificationCenter.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
