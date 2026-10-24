import Foundation
import Testing
@testable import Typeflux

@Suite("Clipboard opening snapshot", .serialized, .exclusiveUIState)
struct ClipboardPanelSnapshotTests {
    @Test func expiresByAgePolicyAndStoreIdentity() {
        let first = NSObject(), second = NSObject(), now = Date(timeIntervalSince1970: 100_000)
        let snapshot = ClipboardPanelSnapshot(entries: [], policy: "policy", store: ObjectIdentifier(first),
                                               retentionDays: nil, uptime: 100)
        #expect(snapshot.isValid(policy: "policy", store: ObjectIdentifier(first), now: now, uptime: 129))
        #expect(!snapshot.isValid(policy: "policy", store: ObjectIdentifier(first), now: now, uptime: 130))
        #expect(!snapshot.isValid(policy: "policy", store: ObjectIdentifier(first), now: now, uptime: 99))
        #expect(!snapshot.isValid(policy: "changed", store: ObjectIdentifier(first), now: now, uptime: 101))
        #expect(!snapshot.isValid(policy: "policy", store: ObjectIdentifier(second), now: now, uptime: 101))
    }

    @Test func expiresAtTheFirstUnpinnedClipboardRetentionBoundary() {
        let now = Date(timeIntervalSince1970: 100_000)
        let item = ClipboardTestSupport.entry(.text, date: now.addingTimeInterval(-86400 + 5))
        let snapshot = ClipboardPanelSnapshot(entries: [item], policy: "p", store: nil, retentionDays: 1, uptime: 100)
        #expect(snapshot.isValid(policy: "p", store: nil, now: now.addingTimeInterval(4), uptime: 104))
        #expect(!snapshot.isValid(policy: "p", store: nil, now: now.addingTimeInterval(5), uptime: 105))
    }

    @Test func permanentAndVoiceEntriesDoNotFollowClipboardExpiry() {
        let now = Date(timeIntervalSince1970: 100_000), old = Date(timeIntervalSince1970: 1)
        var snippet = ClipboardTestSupport.entry(.text, date: old)
        snippet.snippet = .init(name: "Fixture", alias: "fixture")
        let entries = [snippet, ClipboardTestSupport.entry(.text, date: old, isPinned: true),
                       ClipboardTestSupport.entry(.voice, date: old)]
        let snapshot = ClipboardPanelSnapshot(entries: entries, policy: "p", store: nil, retentionDays: 1, uptime: 100)
        #expect(snapshot.isValid(policy: "p", store: nil, now: now, uptime: 101))
        #expect(snapshot.entries == entries)
        let unlimited = ClipboardPanelSnapshot(entries: [ClipboardTestSupport.entry(.text, date: old)],
                                                policy: "p", store: nil, retentionDays: nil, uptime: 100)
        #expect(unlimited.isValid(policy: "p", store: nil, now: now, uptime: 101))
    }

    @Test @MainActor func crossProcessClipboardChangesAreForwardedWithoutContent() async throws {
        #expect(FeatureProcess.sharedNotifications.contains(.clipboardHistoryDidChange))
        var received = 0
        let observer = NotificationCenter.default.addObserver(forName: .clipboardHistoryDidChange,
            object: nil, queue: .main) { notification in
                #expect(notification.userInfo == nil)
                received += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await FeatureProcess.receive(.init(destination: .clipboard, action: "changed",
            payload: Data(Notification.Name.clipboardHistoryDidChange.rawValue.utf8)))
        #expect(received == 1)
    }

    @Test @MainActor func warmupPolicySeparatesEssentialAndDeferredFeatures() {
        #expect(FeatureProcess.immediateWarmRoles == [.voice, .background])
        #expect(FeatureProcess.deferredWarmRoles == [.screenshot])
        #expect(Set(FeatureProcess.immediateWarmRoles).isDisjoint(with: FeatureProcess.deferredWarmRoles))
    }
}
