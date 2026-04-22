@testable import Typeflux
import XCTest

final class CodingAppDetectorTests: XCTestCase {
    func testDetectsXcode() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.dt.Xcode"))
    }

    func testDetectsAppleTerminal() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.Terminal"))
    }

    func testDetectsVSCodeFamily() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.microsoft.VSCode"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.microsoft.VSCodeInsiders"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.visualstudio.code.oss"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.vscodium"))
    }

    func testDetectsCursorAndWindsurf() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.anysphere.cursor"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.exafunction.windsurf"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.trae.app"))
    }

    func testDetectsZedAndNova() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "dev.zed.Zed"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "dev.zed.Zed-Preview"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.panic.Nova"))
    }

    func testDetectsSublimeAndLapce() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.sublimetext.4"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.sublimetext.3"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.lapce.lapce"))
    }

    func testDetectsClassicEditors() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "org.gnu.Emacs"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "org.vim.MacVim"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.macromates.TextMate"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.barebones.bbedit"))
    }

    func testDetectsTerminalEmulators() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.googlecode.iterm2"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "dev.warp.Warp-Stable"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "dev.warp.Warp-Preview"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.mitchellh.ghostty"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "org.alacritty"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "net.kovidgoyal.kitty"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "co.zeit.hyper"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.github.wez.wezterm"))
    }

    func testDetectsJetBrainsFamilyViaPrefix() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.intellij"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.goland"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.PyCharm"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.WebStorm"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.rider"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.rustrover"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrains.fleet"))
    }

    func testDetectsAndroidStudioViaPrefix() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.google.android.studio"))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "com.google.android.studio.preview"))
    }

    func testReturnsFalseForKnownNonCodingApps() {
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.mail"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.Notes"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.finder"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.microsoft.Word"))
    }

    func testReturnsFalseForNilAndEmptyInput() {
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: nil))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: ""))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "   "))
    }

    func testTrimsWhitespaceBeforeMatching() {
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "  com.apple.dt.Xcode  "))
        XCTAssertTrue(CodingAppDetector.isCodingApp(bundleIdentifier: "\tcom.jetbrains.goland\n"))
    }

    func testDoesNotMatchUnrelatedIdentifiersWithSimilarPrefixes() {
        // Prefix must be followed by a dot; bare match with no dot should not false-positive.
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.jetbrainsimpostor"))
        XCTAssertFalse(CodingAppDetector.isCodingApp(bundleIdentifier: "com.apple.dt.XcodePlayground"))
    }
}
