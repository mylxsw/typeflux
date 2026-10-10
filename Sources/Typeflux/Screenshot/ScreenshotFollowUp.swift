import CoreGraphics
import Foundation

/// What happens to a finished screenshot besides copying or saving it. The screenshot
/// module only hands the image over; `ScreenshotFollowUpHandling` decides what that means.
enum ScreenshotFollowUp: String, CaseIterable, Equatable, Sendable {
    /// Recognize its text and show it in the launcher.
    case recognizeText
    /// Recognize its text, then translate it in the launcher.
    case translate
    /// Put it in the launcher as an image attachment of a new question.
    case askAI

    /// The launcher keyword option that names a follow-up (`jtai` → `askAI`).
    static let option = "followUp"

    init?(options: [String: String]) {
        guard let value = options[Self.option].flatMap(Self.init(rawValue:)) else { return nil }
        self = value
    }

    /// The toolbar button's SF Symbol.
    var symbol: String {
        switch self {
        case .recognizeText: "text.viewfinder"
        case .translate: "character.bubble"
        case .askAI: "sparkles"
        }
    }

    var title: String {
        switch self {
        case .recognizeText: L("screenshot.followUp.recognizeText")
        case .translate: L("screenshot.followUp.translate")
        case .askAI: L("screenshot.followUp.askAI")
        }
    }
}

/// A rendered screenshot on its way to a follow-up: marked up and with its mosaics applied,
/// so nothing the user covered leaves the editor.
struct ScreenshotFollowUpImage: @unchecked Sendable {
    let image: CGImage
    /// Pixels per point of the display it came from.
    let scale: CGFloat
    /// A joined scrolling capture rather than one region.
    let isLongImage: Bool

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// Receives screenshots that go on to text recognition, translation or a question.
/// Set by the app; the launcher implements it, so the screenshot module never sees `Ask/`.
@MainActor
protocol ScreenshotFollowUpHandling: AnyObject {
    func handle(_ followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage)
}
