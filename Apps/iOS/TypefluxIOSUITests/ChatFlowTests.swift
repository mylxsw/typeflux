import XCTest

/// Every launch uses the in-memory fixture; these tests never contact Typeflux Cloud.
final class ChatFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReadConversationSwitchModelAndSendFollowUp() {
        let app = launchPreview()
        XCTAssertTrue(app.staticTexts["Synthetic preview · No network"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter start to the day")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Help me make a simple morning routine that leaves room to think."]
            .waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Synthetic preview — conversation")

        app.buttons["Preview model"].tap()
        app.buttons["Text preview model"].tap()
        XCTAssertFalse(app.buttons["Attach photo"].isEnabled)
        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("Help me choose the first step.")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Help me choose the first step."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This is a synthetic preview."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Message Typeflux")
        app.buttons["Refresh conversation"].tap()
        XCTAssertTrue(app.staticTexts["Help me choose the first step."].exists)
    }

    @MainActor
    func testNewConversationSignOutAndSignInValidation() {
        let app = launchPreview()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 10))
        app.buttons["Load more"].tap()
        XCTAssertFalse(app.buttons["Load more"].exists)
        app.buttons["chat.new"].tap()
        XCTAssertTrue(app.staticTexts["What's on your mind?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("A new idea")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.navigationBars["Synthetic conversation"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 5))
        app.buttons["Account"].tap()
        app.buttons["Sign out"].tap()

        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        attachScreenshot(app, name: "Synthetic preview — sign in")
        let email = app.textFields["login.email"]
        email.tap()
        email.typeText("preview@example.invalid")
        XCTAssertFalse(submit.isEnabled)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("invalid")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        password.tap()
        password.typeText("synthetic-password")
        submit.tap()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDesktopToolRunIsReadableAndCanBeStopped() {
        let app = launchPreview(arguments: ["--synthetic-tools"])
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A task from your Mac"))
            .firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        XCTAssertTrue(app.staticTexts["Waiting for the originating device"].waitForExistence(timeout: 5))
        app.buttons["Tool failed"].tap()
        XCTAssertTrue(app.staticTexts["Permission was denied on the Mac."].exists)
        app.buttons["read_file"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["{\"path\":\"notes.txt\"}"].exists)
        attachScreenshot(app, name: "Synthetic preview — desktop tool run")
        app.buttons["Stop response"].tap()
        XCTAssertTrue(app.staticTexts["Response stopped."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.send"].exists)
        XCTAssertFalse(app.buttons["Stop response"].exists)
    }

    @MainActor
    private func launchPreview(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
