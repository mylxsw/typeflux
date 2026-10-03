@testable import Typeflux
import WebKit
import XCTest

@MainActor final class AskPreviewEnginePolicyTests: XCTestCase {
    private final class IgnoringSwitch: NSObject {
        @objc func setEnabled(_: Bool) {}
        @objc func enabled() -> Bool {
            true
        }
    }

    private final class WrongSwitch: NSObject {
        @objc func setEnabled(_: String) {}
        @objc func enabled() -> String {
            "true"
        }
    }

    func testMissingIncompatibleAndIneffectiveEngineSwitchesFailClosed() {
        for object in [NSObject(), IgnoringSwitch(), WrongSwitch()] {
            XCTAssertThrowsError(try AskPreviewEnginePolicy.disable(
                on: object,
                setter: "setEnabled:",
                getter: "enabled"
            )) {
                XCTAssertEqual($0 as? AskArtifactError, .previewDisabled)
            }
        }
        XCTAssertNoThrow(try AskPreviewEnginePolicy.apply(to: WKPreferences()))
    }
}
