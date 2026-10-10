import CoreGraphics
@testable import Typeflux
import XCTest

final class ScreenshotSensitiveInfoTests: XCTestCase {
    private typealias Detector = ScreenshotSensitiveInfoDetector

    private func kinds(_ text: String) -> [ScreenshotSensitiveFinding.Kind] {
        Detector.matches(in: text).map(\.kind)
    }

    private func found(_ text: String) -> [String] {
        let string = text as NSString
        return Detector.matches(in: text).map { string.substring(with: $0.range) }
    }

    // MARK: Phone numbers

    func testMobileNumbersAreFound() {
        XCTAssertEqual(found("联系人：张三 · 138 0013 8000"), ["138 0013 8000"])
        XCTAssertEqual(kinds("13800138000"), [.phone])
        XCTAssertEqual(found("call +86 139-1234-5678 now"), ["+86 139-1234-5678"])
    }

    func testNumbersThatAreNotPhonesAreLeftAlone() {
        XCTAssertEqual(kinds("活跃用户 128,430"), [])
        XCTAssertEqual(kinds("12800138000"), [], "No mobile prefix starts with 12")
        XCTAssertEqual(kinds("2380013800012"), [], "Part of a longer number")
        XCTAssertEqual(kinds("10:30"), [])
    }

    // MARK: Email

    func testEmailAddressesAreFound() {
        XCTAssertEqual(found("zhangsan@example.com"), ["zhangsan@example.com"])
        XCTAssertEqual(found("mail me: a.b+c@mail.example.co.uk."), ["a.b+c@mail.example.co.uk"])
        XCTAssertEqual(kinds("user at example dot com"), [])
        XCTAssertEqual(kinds("@handle and name@host"), [], "Without a domain there is no address")
    }

    // MARK: Bank cards

    func testCardNumbersMustPassTheLuhnCheck() {
        XCTAssertEqual(found("Card 4111 1111 1111 1111 exp"), ["4111 1111 1111 1111"])
        XCTAssertEqual(kinds("6222020200001234562"), [.bankCard])
        XCTAssertEqual(kinds("4111-1111-1111-1111"), [.bankCard])
        XCTAssertEqual(kinds("4111 1111 1111 1112"), [], "Fails the check")
        XCTAssertEqual(kinds("6222020200001234567"), [])
    }

    func testLuhn() {
        XCTAssertTrue(Detector.isLuhnValid("4111111111111111"))
        XCTAssertFalse(Detector.isLuhnValid("4111111111111112"))
        XCTAssertFalse(Detector.isLuhnValid("411111111111"), "Too short")
        XCTAssertFalse(Detector.isLuhnValid("41111111111111111111"), "Too long")
        XCTAssertFalse(Detector.isLuhnValid("0000000000000"), "One repeated digit passes, but is no card")
        XCTAssertFalse(Detector.isLuhnValid("41111111111111a1"))
    }

    // MARK: ID numbers

    func testResidentIDsNeedAValidCheckCharacterAndDate() {
        XCTAssertEqual(found("身份证 11010519491231002X"), ["11010519491231002X"])
        XCTAssertFalse(Detector.isResidentID("440524188001010014"), "Born before 1900")
        XCTAssertEqual(kinds("110105194912310021"), [], "Wrong check character")
        XCTAssertTrue(Detector.isResidentID("11010519491231002x"), "Lowercase x")
        XCTAssertFalse(Detector.isResidentID("110105194913310028"), "Month 13")
        XCTAssertFalse(Detector.isResidentID("110105194912320028"), "Day 32")
        XCTAssertFalse(Detector.isResidentID("1101051949123100"), "Too short")
        XCTAssertFalse(Detector.isResidentID("1101051949123100AX"))
    }

    func testAnIDIsNotAlsoACardOrPhone() {
        XCTAssertEqual(kinds("11010519491231002X"), [.idCard])
    }

    // MARK: Credit codes

    func testCreditCodesNeedAValidCheckCharacter() {
        XCTAssertEqual(found("统一社会信用代码：91350100M000100Y43"), ["91350100M000100Y43"])
        XCTAssertEqual(kinds("91350100M000100Y44"), [])
        XCTAssertTrue(Detector.isCreditCode("91350100m000100y43"))
        XCTAssertFalse(Detector.isCreditCode("91350100M000100Y4"))
        XCTAssertFalse(Detector.isCreditCode("91350100M000100YI3"), "I is not in the alphabet")
    }

    // MARK: Several in a line

    func testSeveralFindingsInOneLineAreInOrder() {
        let text = "张三 138 0013 8000 · zhangsan@example.com"
        XCTAssertEqual(kinds(text), [.phone, .email])
        XCTAssertEqual(found(text), ["138 0013 8000", "zhangsan@example.com"])
    }

    func testTheSystemDetectorAddsOtherPhoneNumbers() {
        // A US number does not match the mobile rule; the system detector finds it.
        XCTAssertEqual(kinds("Call (415) 555-0132 today"), [.phone])
        XCTAssertTrue(Detector.isFormattedPhone("(415) 555-0132"))
        XCTAssertTrue(Detector.isFormattedPhone("+44 20 7946 0958"))
        XCTAssertFalse(Detector.isFormattedPhone("4155550132"), "Bare digits are left to the rules")
        XCTAssertFalse(Detector.isFormattedPhone("555-01"), "Too few digits")
        XCTAssertFalse(Detector.isFormattedPhone("4111 1111 1111 1111 1"), "Too many digits")
    }

    // MARK: Placement

    private func line(_ text: String, box: CGRect = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.05))
        -> RecognizedText.Line {
        RecognizedText.Line(text: text, confidence: 1, boundingBox: box)
    }

    func testFindingsArePlacedOnTheirPartOfTheLine() {
        let text = RecognizedText(lines: [line("abcd 13800138000"), line("nothing here")])
        let findings = Detector.findings(in: text)

        XCTAssertEqual(findings.count, 1)
        let finding = findings[0]
        XCTAssertEqual(finding.kind, .phone)
        XCTAssertEqual(finding.text, "13800138000")
        // 16 characters across 0.8: the number starts after 5, widened by a character.
        let unit = 0.8 / 16
        XCTAssertEqual(finding.boundingBox.minX, 0.1 + 5 * unit - unit, accuracy: 0.0001)
        XCTAssertEqual(finding.boundingBox.maxX, 0.9, accuracy: 0.0001, "Kept on the line")
        XCTAssertEqual(finding.boundingBox.minY, 0.2)
        XCTAssertEqual(finding.boundingBox.height, 0.05)
    }

    func testWideCharactersCountDouble() {
        // "电话" takes four units, then a space, then 11 digits: 16 units.
        let box = Detector.box(of: NSRange(location: 3, length: 11), in: line("电话 13800138000"))
        let unit = 0.8 / 16
        XCTAssertEqual(box.minX, 0.1 + 5 * unit - unit, accuracy: 0.0001)
        XCTAssertTrue(Detector.isWide("中"))
        XCTAssertTrue(Detector.isWide("가"))
        XCTAssertTrue(Detector.isWide("，"))
        XCTAssertFalse(Detector.isWide("a"))
        XCTAssertFalse(Detector.isWide("1"))
    }

    func testTheRecognizersExactBoundsWinOverTheEstimate() {
        var exact = line("abcd 13800138000")
        exact.locate = { range in
            range == NSRange(location: 5, length: 11) ? CGRect(x: 0.4, y: 0.21, width: 0.3, height: 0.04) : nil
        }
        let box = Detector.box(of: NSRange(location: 5, length: 11), in: exact)
        XCTAssertEqual(box.minX, 0.4 - 0.006, accuracy: 0.0001, "Padded by 15% of the height")
        XCTAssertEqual(box.width, 0.3 + 0.012, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 0.21, accuracy: 0.0001)
        // Without exact bounds for that range, the estimate is used.
        XCTAssertEqual(Detector.box(of: NSRange(location: 0, length: 4), in: exact),
                       Detector.estimatedBox(of: NSRange(location: 0, length: 4), in: exact))
        XCTAssertEqual(exact, line("abcd 13800138000"), "The locator is not compared")
    }

    func testPlacementOfOddRangesStaysOnTheLine() {
        let whole = line("")
        XCTAssertEqual(Detector.box(of: NSRange(location: 0, length: 3), in: whole), whole.boundingBox)
        let box = Detector.box(of: NSRange(location: 40, length: 5), in: line("short"))
        XCTAssertGreaterThanOrEqual(box.minX, 0.1)
        XCTAssertLessThanOrEqual(box.maxX, 0.9 + 0.0001)
    }

    func testFindingRectsAndMasks() {
        let finding = ScreenshotSensitiveFinding(kind: .email, text: "zhangsan@example.com",
                                                 boundingBox: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.1))
        XCTAssertEqual(finding.rect(imageSize: CGSize(width: 400, height: 200), scale: 2),
                       CGRect(x: 100, y: 25, width: 50, height: 10))
        XCTAssertEqual(finding.maskedText, "zhang" + String(repeating: "•", count: 10) + "e.com")
        XCTAssertEqual(ScreenshotSensitiveFinding.mask("1234"), "••••")
        let card = ScreenshotSensitiveFinding(kind: .bankCard, text: "6222 0202 0000 1234 562", boundingBox: .zero)
        XCTAssertEqual(card.maskedText, "6222" + String(repeating: "•", count: 11) + "4562", "Spaces left out")
        XCTAssertEqual(ScreenshotSensitiveFinding.mask("13800138000"), "13•••••••00")
        XCTAssertEqual(ScreenshotSensitiveFinding.Kind.allCases.map(\.title).filter(\.isEmpty), [])
    }
}
