import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite("Workflow billing operations", .serialized, .exclusiveUIState)
struct WorkflowBillingOperationTests {
    @Test func currentSuccessAndFailureUseTheOverlayAction() async throws {
        for succeeds in [true, false] {
            try await withOverlay { fixture, controller, button in
                try button.press()
                let task = try await started(fixture, controller)
                fixture.auth.lastAccountSummaryRefresh = Date()
                let summary = fixture.auth.lastAccountSummaryRefresh
                if succeeds { fixture.succeed("workflow") } else { fixture.fail() }
                await task.value
                #expect(fixture.links == (succeeds ? [fixture.expectedURL("workflow")] : []))
                #expect(fixture.auth.lastAccountSummaryRefresh == summary)
                #expect(controller.billingLifetime.isBusy == false)
                #expect(fixture.auth.checkoutPollingTask == nil)
            }
        }
    }

    @Test func defaultFailureReporterStillNavigatesToAccountSettings() async throws {
        try await withOverlay(observeFailures: false) { fixture, controller, button in
            try button.press()
            let task = try await started(fixture, controller)
            fixture.fail()
            await task.value
            #expect(fixture.links.isEmpty)
            #expect(!controller.billingLifetime.isBusy)
        }
    }

    @Test func replacedSessionsSuppressOldBrowserSettingsAndLogOutputs() async throws {
        for replacement in SessionReplacement.allCases {
            for succeeds in [true, false] {
                try await withOverlay(expectFailure: false) { fixture, controller, button in
                    try button.press()
                    let task = try await started(fixture, controller)
                    if replacement == .logout { fixture.auth.logout(clearRecentInputMemory: false) } else {
                        await fixture.auth.handleLoginSuccess(token: "b1", expiresAt: fixture.expiry)
                    }
                    if succeeds { fixture.succeed("old") } else { fixture.fail() }
                    await task.value
                    #expect(fixture.links.isEmpty)
                    #expect(fixture.auth.checkoutPollingTask == nil)
                    #expect(!fixture.auth.pendingCheckoutSubscriptionEntitlement)
                }
            }
        }
    }

    @Test func rotationKeepsResultsAndCancellationKeepsNewBusyOwnership() async throws {
        try await withOverlay { fixture, controller, button in
            try button.press()
            let old = try await started(fixture, controller)
            controller.billingLifetime.cancel()
            #expect(old.isCancelled)
            // Present a fresh overlay and invoke its real action while the old call is held.
            await controller.presentCloudBillingError(.init(reason: .subscriptionRequired, serverMessage: nil))
            let host = try #require(controller.overlayController.presentedWindow?.contentView)
            let fresh = try SettingsBehaviorTestSupport.button(L("cloud.billing.action.subscribe"), in: host)
            try fresh.press()
            let current = try await started(fixture, controller, count: 2)
            fixture.succeed("cancelled")
            await old.value
            #expect(controller.billingLifetime.isBusy)
            #expect(fixture.links.isEmpty)
            fixture.auth.cachedRefreshToken = "rotate"
            #expect(await fixture.auth.refreshStoredAccessToken(force: true) == .refreshed)
            fixture.auth.cachedRefreshToken = nil
            fixture.succeed("rotated")
            await current.value
            #expect(fixture.links == [fixture.expectedURL("rotated")])
            #expect(!controller.billingLifetime.isBusy)
        }
    }

    private func started(_ fixture: BillingOperationFixture, _ controller: WorkflowController,
                         count: Int = 1) async throws -> Task<Void, Never> {
        try await fixture.pages.waitForCalls(count)
        let task = try #require(controller.billingLifetime.task)
        fixture.track(task)
        return task
    }

    private func withOverlay(expectFailure: Bool? = nil, observeFailures: Bool = true,
                             check: (BillingOperationFixture, WorkflowController,
                                     SettingsBehaviorTestSupport.Element) async throws -> Void) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try BillingOperationFixture(.accountPlans, defaults: settings.defaults)
            let controller = WorkflowControllerProcessingTests().makeWorkflowController(settingsStoreOverride: settings)
            controller.billingAuth = { fixture.auth }
            controller.openBillingURL = { fixture.links.append($0) }
            var sections: [StudioSection] = []
            var failures: [String] = []
            controller.presentBillingSettings = { sections.append($0) }
            if observeFailures { controller.reportBillingFailure = { failures.append($0.localizedDescription) } }
            @MainActor func cleanup() async {
                if let task = controller.billingLifetime.task { fixture.track(task) }
                controller.billingLifetime.cancel()
                await fixture.close()
                controller.overlayController.dismissImmediately()
                if let window = controller.overlayController.presentedWindow {
                    window.contentView = nil
                    window.close()
                    #expect(!window.isVisible)
                }
            }
            do {
                await fixture.prepare()
                await controller.presentCloudBillingError(.init(reason: .subscriptionRequired, serverMessage: nil))
                let host = try #require(controller.overlayController.presentedWindow?.contentView)
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("cloud.billing.action.subscribe"), in: host)
                }
                let button = try SettingsBehaviorTestSupport.button(L("cloud.billing.action.subscribe"), in: host)
                try await check(fixture, controller, button)
                let failed = expectFailure ?? fixture.links.isEmpty
                #expect(sections == (failed ? [.account] : []))
                #expect(failures == (failed && observeFailures
                                    ? [BillingOperationFixture.failure.localizedDescription] : []))
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }
}
