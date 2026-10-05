import XCTest

/// These flows drive the shipped views and store with explicitly offline scenarios.
final class ChatVerificationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsAccountAndSignOutConfirmation() {
        let app = launch()
        openHistory(app)
        screenshot(app, "qa-sidebar")
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.language"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["account.credits"].waitForExistence(timeout: 5))
        screenshot(app, "qa-settings-light")
        app.buttons["settings.account"].tap()
        XCTAssertTrue(app.staticTexts["account.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["account.email"].label.contains("preview@example.invalid"))
        screenshot(app, "qa-account")
        app.navigationBars.buttons.firstMatch.tap()
        let signOut = app.buttons["account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        if !signOut.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        signOut.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "account.confirmSignOut").firstMatch
            .waitForExistence(timeout: 5))
        screenshot(app, "qa-signout-confirmation")
        app.buttons.matching(identifier: "account.cancelSignOut").firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.account"].exists)
        if !signOut.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        signOut.tap()
        app.buttons.matching(identifier: "account.confirmSignOut").firstMatch.tap()
        XCTAssertTrue(app.buttons["guest.login"].waitForExistence(timeout: 5))
        app.buttons["guest.login"].tap()
        XCTAssertTrue(app.buttons["login.email.open"].waitForExistence(timeout: 5))
        screenshot(app, "qa-welcome")
        app.buttons["login.email.open"].tap()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        screenshot(app, "qa-login")
        app.buttons["login.forgot"].tap()
        XCTAssertTrue(app.buttons["reset.submit"].waitForExistence(timeout: 5))
        screenshot(app, "qa-password-reset")
    }

    @MainActor
    func testAppearancePersistsAndCanReturnToSystem() {
        let app = launch()
        openHistory(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.appearance.dark"].tap()
        screenshot(app, "qa-settings-dark")
        app.terminate()
        app.launchArguments.append("--synthetic-preserve-settings")
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        openHistory(app)
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.appearance.dark"].isSelected)
        app.buttons["settings.appearance.system"].tap()
        XCTAssertTrue(app.buttons["settings.appearance.system"].isSelected)
    }

    @MainActor
    func testRichReplyReasoningToolsCopyAndActions() {
        let app = launch("--synthetic-rich")
        openHistory(app)
        app.buttons["chat.history.preview-rich"].tap()
        let transcript = app.scrollViews.firstMatch
        for _ in 0 ..< 5 {
            transcript.swipeDown()
        }
        screenshot(app, "qa-rich-conversation")
        let activity = app.buttons["chat.activity.rich-tool-call"]
        reveal(activity, in: transcript, upwards: true)
        XCTAssertEqual(activity.value as? String, "已收起")
        activity.tap()
        let tool = app.buttons["chat.tool.rich-search"]
        reveal(tool, in: transcript, upwards: true)
        tool.tap()
        screenshot(app, "qa-tool-details")
        XCTAssertTrue(app.buttons["结果"].exists)
        app.buttons["参数"].tap()
        screenshot(app, "qa-tool-arguments")
        tool.tap(); activity.tap()
        let reasoning = app.buttons["思考了 4 秒"]
        reveal(reasoning, in: transcript, upwards: true)
        reasoning.tap()
        XCTAssertEqual(reasoning.value as? String, "已展开")
        screenshot(app, "qa-reasoning-expanded")
        let table = app.scrollViews["表格，可横向滚动"]
        reveal(table, in: transcript, upwards: true)
        XCTAssertTrue(app.staticTexts["多端合并"].isHittable)
        XCTAssertTrue(app.staticTexts["方案"].isHittable)
        XCTAssertTrue(app.staticTexts.matching(identifier: "chat.horizontalHint").firstMatch.exists)
        screenshot(app, "qa-markdown-table")
        table.swipeLeft()
        XCTAssertTrue(app.staticTexts["适用场景"].isHittable)
        screenshot(app, "qa-markdown-table-scrolled")
        let copy = app.buttons["复制代码"]
        reveal(copy, in: transcript, upwards: true)
        copy.tap()
        XCTAssertTrue(app.buttons["已复制"].exists)
        screenshot(app, "qa-markdown-code")
        let copyAnswer = app.buttons["chat.copy.rich-answer"]
        reveal(copyAnswer, in: transcript, upwards: true)
        XCTAssertTrue(app.buttons["chat.share.rich-answer"].exists)
        // Only the latest answer can be regenerated.
        XCTAssertFalse(app.buttons["chat.regenerate.rich-answer"].exists)
        copyAnswer.tap()
        XCTAssertEqual(copyAnswer.label, "已复制")
        screenshot(app, "qa-answer-actions")
        app.buttons["chat.quote.rich-answer"].tap()
        XCTAssertTrue((app.textFields["chat.composer"].value as? String)?.contains("> ") == true)
    }

    @MainActor
    func testHistoricalPhotoRendersAndPreventsTextOnlyModel() {
        let app = launch("--synthetic-rich", "--synthetic-dark")
        openHistory(app)
        app.buttons["chat.history.preview-rich"].tap()
        let photo = app.images["chat.photo.rich-image-question.0"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let transcript = app.scrollViews.firstMatch
        let top = app.buttons["chat.sidebar.open"].frame.maxY + 12
        let bottom = app.textFields["chat.composer"].frame.minY - 12
        // isHittable alone can include content behind the floating top bar.
        // Require the complete image inside the reading area before documenting it.
        for _ in 0 ..< 12 {
            if photo.frame.minY >= top, photo.frame.maxY <= bottom {
                break
            }
            let above = photo.frame.minY < top
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.35 : 0.65))
            let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.65 : 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertGreaterThanOrEqual(photo.frame.minY, top)
        XCTAssertLessThanOrEqual(photo.frame.maxY, bottom)
        screenshot(app, "qa-history-photo-dark")
        app.buttons["modelPicker"].tap()
        app.buttons["changeModel"].tap()
        XCTAssertFalse(app.buttons["model-text-preview"].isEnabled)
        XCTAssertTrue(app.buttons["model-preview"].isEnabled)
        screenshot(app, "qa-photo-model-restriction")
    }

    @MainActor
    func testPhotoPickerPreviewRemoveAndSend() {
        let app = launch("--synthetic-empty")
        pickPhoto(app)
        XCTAssertTrue(app.images["chat.photo.preview"].waitForExistence(timeout: 8))
        screenshot(app, "qa-photo-composer")
        app.buttons["chat.photo.remove"].tap()
        XCTAssertFalse(app.images["chat.photo.preview"].exists)
        pickPhoto(app)
        XCTAssertTrue(app.images["chat.photo.preview"].waitForExistence(timeout: 8))
        enter("请描述这张测试图片。", in: app)
        app.buttons["chat.send"].tap()
        let photo = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.photo.")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertFalse(app.images["chat.photo.preview"].exists)
        screenshot(app, "qa-photo-sent")
    }

    @MainActor
    func testStreamingCompletesAndAllowsAnotherTurn() {
        let app = launch("--synthetic-stream", "--synthetic-stream-slow")
        openHistory(app)
        app.buttons["chat.history.preview-stream"].tap()
        enter("给我几个可以开始的步骤。", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["停止生成"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["modelPicker"].isEnabled)
        screenshot(app, "qa-stream-thinking")
        let preview = app.otherElements["chat.run.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let latest = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "最后，为下一步留下一个清楚的小动作。")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        XCTAssertTrue(latest.isHittable)
        screenshot(app, "qa-stream-progress")
        let answer = app.buttons["chat.copy.stream-answer-1"]
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        XCTAssertTrue(answer.isHittable)
        XCTAssertFalse(app.buttons["停止生成"].exists)
        XCTAssertTrue(app.buttons["modelPicker"].isEnabled)
        screenshot(app, "qa-stream-completed")
        enter("再举一个具体的例子。", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.copy.stream-answer-2"].waitForExistence(timeout: 30))
        screenshot(app, "qa-multi-turn")
    }

    @MainActor
    func testStopGenerationPreservesPartialReply() {
        let app = launch("--synthetic-stream", "--synthetic-stream-slow")
        openHistory(app)
        app.buttons["chat.history.preview-stream"].tap()
        enter("详细说明一下这个建议。", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.otherElements["chat.run.preview"].waitForExistence(timeout: 15))
        app.buttons["停止生成"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.stopped"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.header.status"].label, "已停止")
        XCTAssertEqual(app.staticTexts["chat.run.stopped"].label, "已停止生成")
        XCTAssertFalse(app.staticTexts["chat.run.error"].exists)
        XCTAssertTrue(app.otherElements["chat.run.preview"].exists)
        XCTAssertTrue(app.buttons["modelPicker"].isEnabled)
        screenshot(app, "qa-stream-stopped")
    }

    @MainActor
    func testFailedRunIsReadableAndCanContinue() {
        let app = launch("--synthetic-failure")
        openHistory(app)
        app.buttons["chat.history.preview-failure"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.header.status"].label, "失败")
        screenshot(app, "qa-run-failed")
        enter("请继续说明冲突处理。", in: app)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        app.buttons["chat.send"].tap()
        XCTAssertFalse(app.staticTexts["chat.run.error"].exists)
        screenshot(app, "qa-failure-followup")
    }

    @MainActor
    func testHistoryPaginationSearchAndEmptyConversation() {
        let app = launch("--synthetic-history")
        openHistory(app)
        screenshot(app, "qa-history-groups")
        for _ in 0 ..< 3 {
            let more = app.buttons["chat.loadMore"]
            reveal(more, in: app.collectionViews.firstMatch, upwards: true)
            more.tap()
        }
        let search = app.textFields["chat.search"]
        search.tap(); search.typeText("灵感")
        XCTAssertTrue(app.buttons["chat.history.history-13"].waitForExistence(timeout: 5))
        screenshot(app, "qa-history-search")
        app.buttons["chat.history.history-13"].tap()
        XCTAssertTrue(app.buttons["chat.copy.history-answer-13"].waitForExistence(timeout: 5))
        app.buttons["chat.detail.new"].tap()
        XCTAssertTrue(app.staticTexts["有什么想问的？"].waitForExistence(timeout: 5))
        screenshot(app, "qa-new-conversation")
    }

    @MainActor
    func testSidebarSearchDeleteAndAccountFooter() {
        let app = launch()
        openHistory(app)
        let search = app.textFields["chat.search"]
        search.tap(); search.typeText("quieter\n")
        XCTAssertTrue(app.buttons["chat.history.preview"].isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        screenshot(app, "qa-sidebar-search")
        app.buttons["chat.search.clear"].tap()
        let row = app.buttons["chat.history.preview"]
        XCTAssertTrue(row.exists)
        row.swipeLeft()
        let delete = app.buttons["chat.history.delete.preview"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons.matching(identifier: "chat.history.confirmDelete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        screenshot(app, "qa-sidebar-delete")
        confirm.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
        // The identity area, not just the gear, must open settings.
        app.buttons["chat.account"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLoginLabelsAndKeyboardNextThenGo() {
        let app = launch()
        openHistory(app)
        app.buttons["chat.account"].tap()
        let signOut = app.buttons["account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        if !signOut.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        signOut.tap()
        app.buttons.matching(identifier: "account.confirmSignOut").firstMatch.tap()
        XCTAssertTrue(app.buttons["guest.login"].waitForExistence(timeout: 5))
        app.buttons["guest.login"].tap()
        let entry = app.buttons["login.email.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let email = app.textFields["login.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        // The email field is focused when the page opens.
        email.typeText("preview@example.invalid\n")
        let password = app.secureTextFields["login.password"]
        // Typing without a tap verifies that Next transferred focus.
        password.typeText("synthetic-password")
        XCTAssertFalse(app.staticTexts["login.email.label"].exists)
        XCTAssertFalse(app.staticTexts["login.password.label"].exists)
        screenshot(app, "qa-login-filled")
        password.typeText("\n")
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 5))
    }
}

private extension ChatVerificationTests {
    @MainActor
    func launch(_ arguments: String...) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app
            .launchArguments = ["--synthetic-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] +
            arguments
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func openHistory(_ app: XCUIApplication) {
        app.buttons["chat.sidebar.open"].tap()
        let account = app.buttons["chat.account"]
        let visible = NSPredicate { _, _ in
            account.exists && account.isHittable && account.frame.minX >= 0
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)],
                                      timeout: 5), .completed)
    }

    @MainActor
    func enter(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText(text)
    }

    @MainActor
    func reveal(_ element: XCUIElement, in scroll: XCUIElement, upwards: Bool) {
        let app = XCUIApplication()
        for _ in 0 ..< 14 {
            var upwards = upwards
            if element.exists, element.isHittable {
                guard let below = outsideReadingArea(element, app: app) else { return }
                // Hittable but under the glass: scroll toward it.
                upwards = below
            }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upwards ? 0.72 : 0.30))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upwards ? 0.30 : 0.72))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    /// isHittable alone accepts content under the floating top bar or composer,
    /// where a tap lands on the glass instead. Returns nil inside the reading
    /// area (or when the element is taller than it), true when it sits below.
    @MainActor
    func outsideReadingArea(_ element: XCUIElement, app: XCUIApplication) -> Bool? {
        let bar = app.buttons["chat.sidebar.open"], field = app.textFields["chat.composer"]
        guard bar.exists, field.exists else { return nil }
        let top = bar.frame.maxY + 12, bottom = field.frame.minY - 24
        let frame = element.frame
        if frame.height > bottom - top || (frame.minY >= top && frame.maxY <= bottom) {
            return nil
        }
        return frame.maxY > bottom
    }

    @MainActor
    func pickPhoto(_ app: XCUIApplication) {
        app.buttons["chat.attach"].tap()
        let library = app.buttons["chat.attach.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let photo = app.images.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "PXGGridLayout-Info", "照片,", "Photo,"
        )).firstMatch
        if !photo.waitForExistence(timeout: 20) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "photo-picker-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("The Photos picker must contain the seeded test image.")
            return
        }
        screenshot(app, "qa-photo-picker")
        // The system's PXG image nodes expose frames but no AX activation point.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    func screenshot(_: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension ChatVerificationTests {
    @MainActor
    func testGuestWelcomeExamplesAndPreservedDraft() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--synthetic-preview",
            "--synthetic-guest",
            "-AppleLanguages",
            "(zh-Hans)",
            "-AppleLocale",
            "zh_CN",
            "-guest.welcome-dismissed",
            "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["login.close"].waitForExistence(timeout: 8))
        screenshot(app, "gul217-welcome")
        app.buttons["login.close"].tap()
        XCTAssertTrue(app.buttons["guest.login"].waitForExistence(timeout: 5))
        screenshot(app, "gul217-guest-home")
        app.buttons["guest.example.email"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["guest.example"].waitForExistence(timeout: 5))
        screenshot(app, "gul217-local-example")
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("Keep my draft")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["login.close"].waitForExistence(timeout: 5))
        screenshot(app, "gul217-login-draft")
        app.buttons["login.close"].tap()
        XCTAssertEqual(field.value as? String, "Keep my draft")
        app.buttons["chat.sidebar.open"].tap()
        screenshot(app, "gul217-guest-sidebar")
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.signOut"].exists)
        XCTAssertFalse(app.buttons["settings.deleteAccount"].exists)
    }

    @MainActor
    func testConsentDeclineAndManualSend() {
        let app = launch("--synthetic-empty", "--synthetic-no-consent")
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("Review then send")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["privacy.decline"].waitForExistence(timeout: 5))
        screenshot(app, "gul217-ai-consent")
        app.buttons["privacy.decline"].tap()
        XCTAssertEqual(field.value as? String, "Review then send")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["privacy.agree"].waitForExistence(timeout: 5))
        app.buttons["privacy.agree"].tap()
        XCTAssertEqual(field.value as? String, "Review then send")
        screenshot(app, "gul217-draft-after-consent")
        app.buttons["chat.send"].tap()
        XCTAssertNotEqual(field.value as? String, "Review then send")
    }

    @MainActor
    func testPrivateReportAndAccountDeletion() {
        let app = launch("--synthetic-empty")
        enter("A short answer for reporting", in: app)
        app.buttons["chat.send"].tap()
        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.report.")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        let submit = app.buttons["report.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isHittable)
        screenshot(app, "gul217-report-answer")
        submit.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons.firstMatch.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5))
        openHistory(app)
        app.buttons["chat.account"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.done"].isHittable)
        screenshot(app, "gul217-settings")
        let deletion = app.buttons["settings.deleteAccount"]
        for _ in 0 ..< 4 where !deletion.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        deletion.tap()
        XCTAssertTrue(app.switches["account.delete.confirm"].waitForExistence(timeout: 5))
        screenshot(app, "gul217-delete-account")
        // SwiftUI exposes the entire labelled row as a switch. Tap its trailing control.
        app.switches["account.delete.confirm"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["account.delete.confirm"].value as? String, "1")
        let password = app.secureTextFields["account.delete.password"]
        password.tap(); password.typeText("proof")
        let remove = app.buttons["account.delete.submit"]
        if !remove.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        let deletionResult = XCTAttachment(string: app.debugDescription)
        deletionResult.name = "account-deletion-result"
        deletionResult.lifetime = .keepAlways
        add(deletionResult)
        XCTAssertTrue(app.buttons["guest.login"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.account"].exists)
    }
}

extension ChatVerificationTests {
    @MainActor
    func testWithdrawConsentInSettings() {
        let app = launch("--synthetic-empty")
        openHistory(app)
        app.buttons["chat.account"].tap()
        let privacy = app.buttons["settings.aiPrivacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        let revoke = app.buttons["privacy.revoke"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5))
        revoke.tap()
        XCTAssertTrue(revoke.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.done"].tap()
        enter("Consent is required again", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["privacy.decline"].waitForExistence(timeout: 5))
    }
}

extension ChatVerificationTests {
    @MainActor
    func testGuestSettingsLoginPreservesDraftThroughConsent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--synthetic-preview",
            "--synthetic-guest",
            "--synthetic-no-consent",
            "-AppleLanguages",
            "(zh-Hans)",
            "-AppleLocale",
            "zh_CN",
            "-guest.welcome-dismissed",
            "YES"
        ]
        app.launch()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Draft before sign-in")
        openHistory(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.login"].tap()
        XCTAssertTrue(app.buttons["login.email.open"].waitForExistence(timeout: 5))
        app.buttons["login.email.open"].tap()
        app.textFields["login.email"].tap()
        app.textFields["login.email"].typeText("preview@example.invalid")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("proof")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["privacy.agree"].waitForExistence(timeout: 8))
        app.buttons["privacy.agree"].tap()
        XCTAssertEqual(composer.value as? String, "Draft before sign-in")
        XCTAssertFalse(app.buttons["guest.login"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.report.")).firstMatch
            .exists)
        screenshot(app, "gul217-draft-after-login")
    }
}
