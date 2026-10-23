import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsChangeObserverTests {
    @Test func backgroundPostingReleasesItsLockWithoutWaitingForMainThread() async throws {
        let center = NotificationCenter()
        let lock = NSLock()
        let posted = DispatchSemaphore(value: 0)
        var delivered = false
        let observer = SettingsChangeObserver.observe(center: center) {
            #expect(Thread.isMainThread)
            // A synchronous main-queue observer would run while the posting
            // thread still owns this lock, exactly as the analytics queue does.
            let available = lock.try()
            #expect(available)
            if available { lock.unlock() }
            delivered = true
        }
        defer { center.removeObserver(observer) }

        DispatchQueue.global().async {
            lock.lock()
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            lock.unlock()
            posted.signal()
        }
        // Hold the main thread briefly: the background poster must still finish.
        #expect(posted.wait(timeout: .now() + 1) == .success)
        for _ in 0..<100 where !delivered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered)
    }

    @Test func mainThreadPostingDefersCallbacksUntilAfterTheMutationReturns() async throws {
        let center = NotificationCenter()
        var delivered = false
        let observer = SettingsChangeObserver.observe(center: center) { delivered = true }
        defer { center.removeObserver(observer) }
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(!delivered)
        for _ in 0..<100 where !delivered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered)
    }

    @Test func observerCanBeRemovedAndIgnoresOtherNotifications() async throws {
        let center = NotificationCenter()
        var count = 0
        let observer = SettingsChangeObserver.observe(center: center) { count += 1 }
        center.post(name: Notification.Name("Unrelated"), object: nil)
        center.removeObserver(observer)
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(count == 0)
    }
}
