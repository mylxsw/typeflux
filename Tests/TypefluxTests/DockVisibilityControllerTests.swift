import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class DockVisibilityControllerTests: XCTestCase {
    func testShowsDockIconWhenFirstWindowAppears() {
        let app = FakeActivationPolicyController(initialPolicy: .accessory)
        let controller = DockVisibilityController(app: app)

        controller.setPresented(true, for: NSObject())

        XCTAssertEqual(app.currentActivationPolicy, .regular)
        XCTAssertEqual(app.appliedPolicies, [.regular])
    }

    func testHidesDockIconWhenLastWindowCloses() {
        let app = FakeActivationPolicyController(initialPolicy: .accessory)
        let controller = DockVisibilityController(app: app)
        let token = NSObject()

        controller.setPresented(true, for: token)
        controller.setPresented(false, for: token)

        XCTAssertEqual(app.currentActivationPolicy, .accessory)
        XCTAssertEqual(app.appliedPolicies, [.regular, .accessory])
    }

    func testKeepsDockIconVisibleWhileAnotherWindowIsStillOpen() {
        let app = FakeActivationPolicyController(initialPolicy: .accessory)
        let controller = DockVisibilityController(app: app)
        let first = NSObject()
        let second = NSObject()

        controller.setPresented(true, for: first)
        controller.setPresented(true, for: second)
        controller.setPresented(false, for: first)

        XCTAssertEqual(app.currentActivationPolicy, .regular)
        XCTAssertEqual(app.appliedPolicies, [.regular])
    }

    func testIgnoresDuplicateVisibilityUpdates() {
        let app = FakeActivationPolicyController(initialPolicy: .accessory)
        let controller = DockVisibilityController(app: app)
        let token = NSObject()

        controller.setPresented(true, for: token)
        controller.setPresented(true, for: token)
        controller.setPresented(false, for: token)
        controller.setPresented(false, for: token)

        XCTAssertEqual(app.appliedPolicies, [.regular, .accessory])
    }
}

private final class FakeActivationPolicyController: ActivationPolicyControlling {
    private(set) var currentActivationPolicy: NSApplication.ActivationPolicy
    private(set) var appliedPolicies: [NSApplication.ActivationPolicy] = []

    init(initialPolicy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = initialPolicy
    }

    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        appliedPolicies.append(policy)
        currentActivationPolicy = policy
    }
}
