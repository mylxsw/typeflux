import AppKit

struct RecordingHintLayout {
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9
    static let containerInset: CGFloat = 34
    static let spacing: CGFloat = 10
    static let maximumWidth: CGFloat = 352

    let textSize: CGSize

    init(text: String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        let naturalWidth = (text as NSString).size(withAttributes: attributes).width
        let width = min(ceil(naturalWidth), Self.maximumWidth - Self.horizontalPadding * 2)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        textSize = CGSize(width: width, height: ceil(bounds.height) + 2)
    }

    var size: CGSize {
        CGSize(
            width: textSize.width + Self.horizontalPadding * 2,
            height: textSize.height + Self.verticalPadding * 2
        )
    }

    var cornerRadius: CGFloat { min(18, size.height / 2) }
}
