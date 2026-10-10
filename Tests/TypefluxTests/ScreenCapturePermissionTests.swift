import Foundation
import Testing
@testable import Typeflux

@Suite("Screen capture permission")
struct ScreenCapturePermissionTests {
    /// The system calls, replaced and counted.
    private final class System {
        var granted = false
        var grantsRequest = false
        var requests = 0
        var opened: [URL] = []
        let suite = "screen-capture-permission-" + UUID().uuidString
        lazy var defaults = UserDefaults(suiteName: suite)!

        func permission() -> ScreenCapturePermission {
            ScreenCapturePermission(defaults: defaults, preflight: { self.granted }, requestAccess: {
                self.requests += 1
                self.granted = self.grantsRequest
                return self.granted
            }, openURL: { self.opened.append($0) })
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func readingAccessNeverRequestsIt() {
        let system = System()
        let permission = system.permission()
        #expect(!permission.isGranted)
        system.granted = true
        #expect(permission.isGranted)
        #expect(system.requests == 0)
    }

    @Test func requestSkipsTheSystemWhenAlreadyGranted() {
        let system = System()
        system.granted = true
        #expect(system.permission().request())
        #expect(system.requests == 0)
    }

    @Test func requestAsksTheSystemWhenMissing() {
        let system = System()
        let permission = system.permission()
        #expect(!permission.request())
        system.grantsRequest = true
        #expect(permission.request())
        #expect(system.requests == 2)
    }

    @Test func requestOnceAsksOnlyTheFirstTime() {
        let system = System()
        let permission = system.permission()
        permission.requestOnce()
        permission.requestOnce()
        #expect(system.requests == 1)
        #expect(system.defaults.bool(forKey: ScreenCapturePermission.requestedKey))
    }

    @Test func requestOnceStaysSilentWhenGranted() {
        let system = System()
        system.granted = true
        system.permission().requestOnce()
        #expect(system.requests == 0)
        #expect(!system.defaults.bool(forKey: ScreenCapturePermission.requestedKey))
    }

    @Test func opensTheScreenRecordingPane() {
        let system = System()
        system.permission().openSystemSettings()
        #expect(system.opened == [ScreenCapturePermission.settingsURL].compactMap { $0 })
        #expect(system.opened.first?.absoluteString.contains("Privacy_ScreenCapture") == true)
    }

    @Test func requestOrOpenSettingsOpensOnlyWhileMissing() {
        let system = System()
        let permission = system.permission()
        permission.requestOrOpenSettings()
        #expect(system.requests == 1 && system.opened.count == 1)
        system.grantsRequest = true
        permission.requestOrOpenSettings()
        #expect(system.requests == 2 && system.opened.count == 1)
    }

    @Test func registerAndOpenSettingsAlwaysOpens() {
        let system = System()
        let permission = system.permission()
        permission.registerAndOpenSettings()
        #expect(system.requests == 1 && system.opened.count == 1)
        system.granted = true
        permission.registerAndOpenSettings()
        #expect(system.requests == 1 && system.opened.count == 2)
    }

    @Test func agentSettingsUseTheSharedPermission() {
        let fake = FakeScreenCapturePermission()
        let permissions = AgentAutomationPermissions.system(screenCapture: fake)
        #expect(!permissions.screenRecordingGranted())
        fake.granted = true
        #expect(permissions.screenRecordingGranted())
    }
}
