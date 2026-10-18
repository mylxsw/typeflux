import XCTest

/// Walks every screen and dialog with offline fixtures and attaches a named
/// screenshot of each, for design review. Each step also asserts the flow works.
final class ScreenTourTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTourGuestAndSignIn() {
        let app = launch("--synthetic-guest", "-guest.welcome-dismissed", "NO")
        XCTAssertTrue(app.buttons["login.close"].waitForExistence(timeout: 8))
        capture("01-welcome")
        app.buttons["login.browse"].tap()
        XCTAssertTrue(app.buttons["guest.login"].waitForExistence(timeout: 5))
        capture("02-guest-home")
        app.buttons["guest.example.email"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["guest.example"].waitForExistence(timeout: 5))
        capture("03-guest-example")
        app.buttons["chat.sidebar.open"].tap()
        XCTAssertTrue(app.buttons["chat.account"].waitForExistence(timeout: 5))
        capture("04-guest-sidebar")
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 5))
        capture("05-guest-settings")
        app.buttons["settings.login"].tap()
        XCTAssertTrue(app.buttons["login.email.open"].waitForExistence(timeout: 5))
        app.buttons["login.email.open"].tap()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
        capture("06-email-sign-in")
        app.textFields["login.email"].typeText("preview@example.invalid")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("proof")
        capture("07-email-sign-in-filled")
        app.buttons["login.forgot"].tap()
        XCTAssertTrue(app.buttons["reset.submit"].waitForExistence(timeout: 5))
        capture("08-password-reset")
        app.buttons["reset.submit"].tap()
        XCTAssertTrue(app.textFields["reset.code"].waitForExistence(timeout: 5))
        app.textFields["reset.code"].tap()
        app.textFields["reset.code"].typeText("000000")
        let newPassword = app.secureTextFields["reset.password"]
        newPassword.tap()
        // A new-password field can offer iOS's strong password first; type our own.
        let ownPassword = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "自己的密码", "Own Password"
        )).firstMatch
        if ownPassword.waitForExistence(timeout: 2) {
            ownPassword.tap()
            newPassword.tap()
        }
        for character in "Preview2026" {
            newPassword.typeText(String(character))
        }
        let typed = (newPassword.value as? String)?.count ?? 0
        XCTAssertEqual(typed, 11, "Every typed character must stay in the new password field")
        capture("09-password-reset-code")
        XCTAssertTrue(app.buttons["reset.submit"].isEnabled)
        app.buttons["reset.submit"].tap()
        let wrongCode = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "验证码不正确")).firstMatch
        if !wrongCode.waitForExistence(timeout: 5) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "reset-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("A wrong code must be explained")
        }
        capture("09b-password-reset-wrong-code")
    }

    @MainActor
    func testTourConversationAndComposer() {
        let app = launch("--synthetic-empty", "--synthetic-no-consent")
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 8))
        capture("10-new-conversation")
        app.buttons["chat.attach"].tap()
        capture("11-attach-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        app.buttons["modelPicker"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reasoningSlider"].waitForExistence(timeout: 5))
        capture("12-model-reasoning-card")
        if app.buttons["changeModel"].waitForExistence(timeout: 3) {
            app.buttons["changeModel"].tap()
            capture("13-model-list")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("帮我写一段周会开场白")
        capture("14-composer-typing")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["privacy.agree"].waitForExistence(timeout: 5))
        capture("15-ai-consent")
        app.buttons["privacy.agree"].tap()
        app.buttons["chat.send"].tap()
        let more = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.more.")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        capture("16-first-answer")
        more.tap()
        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.report.")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        capture("16b-answer-more-menu")
        report.tap()
        XCTAssertTrue(app.buttons["report.submit"].waitForExistence(timeout: 5))
        capture("17-report-answer")
    }

    @MainActor
    func testTourRichFailureAndDesktopRuns() {
        var app = launch("--synthetic-rich")
        openSidebar(app)
        capture("18-sidebar-history")
        app.buttons["chat.history.preview-rich"].tap()
        XCTAssertTrue(app.buttons["chat.detail.new"].waitForExistence(timeout: 5))
        capture("19-rich-conversation-bottom")
        app.scrollViews.firstMatch.swipeDown(); app.scrollViews.firstMatch.swipeDown()
        capture("20-rich-conversation-middle")
        app.terminate()

        app = launch("--synthetic-failure")
        openSidebar(app)
        app.buttons["chat.history.preview-failure"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.run.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.run.retry"].exists)
        capture("21-failed-run")
        app.buttons["chat.run.retry"].tap()
        capture("21b-failed-run-retried")
        app.terminate()

        app = launch("--synthetic-tools")
        openSidebar(app)
        app.buttons["chat.history.preview-tools"].tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 5))
        capture("22-waiting-for-mac")
        app.terminate()

        app = launch("--synthetic-stream", "--synthetic-stream-slow")
        openSidebar(app)
        app.buttons["chat.history.preview-stream"].tap()
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("继续")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 5))
        capture("23-streaming")
    }

    @MainActor
    func testTourSidebarSettingsAndAccount() {
        let app = launch("--synthetic-history")
        openSidebar(app)
        app.textFields["chat.search"].tap()
        app.textFields["chat.search"].typeText("zzz-no-match")
        capture("24-sidebar-search-empty")
        app.buttons["chat.search.clear"].tap()
        app.textFields["chat.search"].typeText("\n")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.preview"))
            .firstMatch
        if row.waitForExistence(timeout: 5) {
            row.swipeLeft()
            capture("25-sidebar-swipe-delete")
            let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.delete."))
                .firstMatch
            if delete.waitForExistence(timeout: 3) {
                delete.tap()
                capture("26-delete-conversation-confirm")
                if app.buttons["chat.history.confirmDelete"].waitForExistence(timeout: 3) {
                    app.buttons["chat.history.confirmDelete"].tap()
                }
            }
        }
        if !app.buttons["chat.account"].isHittable {
            openSidebar(app)
        }
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: 5))
        capture("27-settings-top")
        app.scrollViews.firstMatch.swipeUp()
        capture("28-settings-bottom")
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["settings.account"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.root"].waitForExistence(timeout: 5))
        capture("29-account")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.aiPrivacy"].tap()
        XCTAssertTrue(app.buttons["privacy.revoke"].waitForExistence(timeout: 5))
        capture("30-data-privacy")
        app.navigationBars.buttons.firstMatch.tap()
        let deletion = app.buttons["settings.deleteAccount"]
        for _ in 0 ..< 4 where !deletion.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        deletion.tap()
        XCTAssertTrue(app.switches["account.delete.confirm"].waitForExistence(timeout: 5))
        capture("31-delete-account")
        app.swipeUp()
        capture("32-delete-account-bottom")
        app.navigationBars.buttons.firstMatch.tap()
        let signOut = app.buttons["account.signOut"]
        for _ in 0 ..< 4 where !signOut.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        signOut.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "account.confirmSignOut").firstMatch
            .waitForExistence(timeout: 5))
        capture("33-sign-out-confirm")
    }

    /// GUL-418: Typeflux unreachable, a private conversation with the user's own
    /// provider, the model picker sections, history filter and provider settings.
    @MainActor
    func testTourOfflineAndPrivateConversations() {
        let app = launch("--synthetic-offline", "--synthetic-providers", "--synthetic-history")
        XCTAssertTrue(app.descendants(matching: .any)["connectivity.banner"].waitForExistence(timeout: 10))
        capture("40-offline-banner")
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("服务挂了还能发吗")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.composer.private"].waitForExistence(timeout: 5))
        capture("41-offline-send-kept-draft")
        app.buttons["chat.composer.private"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.empty.subtitle"].waitForExistence(timeout: 5))
        capture("42-private-new-conversation")
        app.buttons["chat.send"].tap()
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                                         "chat.model.")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        capture("43-private-answer")
        app.buttons["modelPicker"].tap()
        if app.buttons["changeModel"].waitForExistence(timeout: 3) {
            app.buttons["changeModel"].tap()
        }
        capture("44-model-picker-private")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        openSidebar(app)
        XCTAssertTrue(app.descendants(matching: .any)["chat.history.filter"].waitForExistence(timeout: 5))
        capture("45-sidebar-filter")
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.providers"].waitForExistence(timeout: 5))
        capture("46-settings-models-storage")
        app.buttons["settings.providers"].tap()
        XCTAssertTrue(app.buttons["providers.add"].waitForExistence(timeout: 5))
        capture("47-model-providers")
        app.buttons["providers.add"].tap()
        XCTAssertTrue(app.buttons["provider.test"].waitForExistence(timeout: 5))
        capture("48-add-provider")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.defaultModel"].tap()
        XCTAssertTrue(app.buttons["defaultModel.reset"].waitForExistence(timeout: 5))
        capture("49-default-model")
    }

    /// GUL-418 follow-ups: a temporary conversation and renaming from the sidebar.
    @MainActor
    func testTourTemporaryAndRename() {
        let app = launch("--synthetic-history")
        XCTAssertTrue(app.buttons["chat.temporary"].waitForExistence(timeout: 8))
        app.buttons["chat.temporary"].tap()
        capture("52-temporary-new")
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("只问一次")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.temporary.keep"].waitForExistence(timeout: 8))
        capture("53-temporary-conversation")
        openSidebar(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.preview"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["只问一次"].exists, "Temporary conversations are never listed")
        row.swipeLeft()
        let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.rename."))
            .firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()
        let title = app.textFields["chat.rename.field"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.press(forDuration: 1.0)
        if app.menuItems["全选"].waitForExistence(timeout: 2) {
            app.menuItems["全选"].tap()
        }
        title.typeText("新的标题")
        capture("54-rename")
        app.buttons["chat.rename.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新的标题")).firstMatch
            .waitForExistence(timeout: 5))
        capture("55-renamed")
    }

    @MainActor
    func testTourWelcomeOwnModels() {
        let app = launch("--synthetic-guest", "-guest.welcome-dismissed", "NO")
        XCTAssertTrue(app.buttons["login.provider"].waitForExistence(timeout: 8))
        capture("50-welcome-own-models")
        app.buttons["login.provider"].tap()
        XCTAssertTrue(app.buttons["provider.test"].waitForExistence(timeout: 5))
        capture("51-welcome-add-provider")
    }

    @MainActor
    func testTourDarkEnglish() {
        let app = launch("--synthetic-rich", "--synthetic-dark", language: "en")
        capture("34-dark-new-conversation")
        openSidebar(app)
        capture("35-dark-sidebar")
        app.buttons["chat.history.preview-rich"].tap()
        XCTAssertTrue(app.buttons["chat.detail.new"].waitForExistence(timeout: 5))
        capture("36-dark-conversation")
        openSidebar(app)
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: 5))
        capture("37-dark-settings")
    }

    @MainActor
    func testTourCreditsAndPurchase() {
        var app = launch("--synthetic-paused")
        openSidebar(app)
        app.buttons["chat.history.preview-paused"].tap()
        XCTAssertTrue(app.buttons["chat.credits.buy"].waitForExistence(timeout: 5))
        capture("38-paused-out-of-credits")
        app.buttons["chat.credits.buy"].tap()
        XCTAssertTrue(app.buttons["credits.buy.pack_m"].waitForExistence(timeout: 8))
        capture("39-credit-shop")
        app.buttons["credits.buy.pack_m"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["credits.notice"].waitForExistence(timeout: 8))
        capture("40-credit-shop-delivered")
        app.buttons["credits.done"].tap()
        XCTAssertTrue(app.buttons["chat.credits.resume"].waitForExistence(timeout: 5))
        app.buttons["chat.credits.resume"].tap()
        XCTAssertTrue(app.buttons["chat.credits.buy"].waitForNonExistence(timeout: 8))
        capture("41-resumed-after-purchase")
        openSidebar(app)
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.buyCredits"].waitForExistence(timeout: 5))
        capture("42-settings-with-addon-credits")
        app.terminate()

        app = launch("--synthetic-empty", "--synthetic-no-credits")
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap(); field.typeText("帮我总结今天的会议")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.credits.buy"].waitForExistence(timeout: 8))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        capture("43-send-refused-out-of-credits")
        app.terminate()

        app = launch("--synthetic-no-store", "--synthetic-purchase-pending")
        openSidebar(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.buyCredits"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["credits.message"].waitForExistence(timeout: 8))
        capture("44-credit-shop-unavailable")
    }

    @MainActor
    func testTourPendingPurchaseEnglish() {
        let app = launch("--synthetic-purchase-pending", language: "en")
        openSidebar(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.buyCredits"].tap()
        XCTAssertTrue(app.buttons["credits.buy.pack_s"].waitForExistence(timeout: 8))
        app.buttons["credits.buy.pack_s"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["credits.notice"].waitForExistence(timeout: 8))
        capture("45-credit-shop-pending-english")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: String..., language: String = "zh-Hans") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(\(language))", "-AppleLocale",
                               language == "en" ? "en_US" : "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSidebar(_ app: XCUIApplication) {
        app.buttons["chat.sidebar.open"].tap()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
        // Let the slide-in settle so the capture is not mid-animation.
        _ = app.buttons["chat.account"].waitForExistence(timeout: 2)
        Thread.sleep(forTimeInterval: 0.6)
    }

    @MainActor
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tour-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
