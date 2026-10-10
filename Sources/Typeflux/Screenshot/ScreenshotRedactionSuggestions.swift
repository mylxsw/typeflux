import CoreGraphics
import Foundation

/// Finds sensitive text on a screenshot, on this Mac.
protocol ScreenshotSensitiveInfoScanning {
    func scan(_ image: CGImage) async -> [ScreenshotSensitiveFinding]
}

/// Reads the image with Vision (band by band for a long one) and runs the detector's rules.
struct VisionSensitiveInfoScanner: ScreenshotSensitiveInfoScanning {
    var recognizer: any ImageTextRecognizing = TiledImageTextRecognizer(base: VisionImageTextRecognizer())

    func scan(_ image: CGImage) async -> [ScreenshotSensitiveFinding] {
        guard let text = try? await recognizer.recognizeText(in: .image(image)) else { return [] }
        return ScreenshotSensitiveInfoDetector.findings(in: text)
    }
}

/// The mosaics the sensitive information panel suggests. Pure state: nothing is covered until
/// the user ticks an item or covers them all, and the ticks follow the document, so undoing a
/// mosaic unticks its item.
struct ScreenshotRedactionSuggestions: Equatable {
    struct Item: Equatable, Identifiable {
        var finding: ScreenshotSensitiveFinding
        /// Where to put the mosaic, in the editor's points.
        var rect: CGRect

        var id: UUID { finding.id }
    }

    enum Status: Equatable {
        case idle, scanning, done
    }

    /// Room added around found text, in points, so the mosaic covers it whole.
    static let padding: CGFloat = 2

    private(set) var status: Status = .idle
    private(set) var items: [Item] = []
    /// The mosaic added for each item, by item id.
    private(set) var mosaics: [UUID: UUID] = [:]
    /// The user closed the panel.
    var isDismissed = false

    mutating func beginScan() {
        status = .scanning
    }

    /// Places what the scan found on an image of `imageSize` pixels at `scale` pixels per point.
    mutating func finishScan(_ findings: [ScreenshotSensitiveFinding], imageSize: CGSize, scale: CGFloat) {
        status = .done
        items = findings.map { finding in
            let rect = finding.rect(imageSize: imageSize, scale: scale)
            return Item(finding: finding, rect: rect.insetBy(dx: -Self.padding, dy: -Self.padding))
        }
    }

    /// The items inside the chosen region (all of them without one): at least half of each must be in it.
    func visibleItems(in crop: CGRect?) -> [Item] {
        guard let crop else { return items }
        return items.filter { item in
            let shared = item.rect.intersection(crop)
            return !shared.isNull && shared.width * shared.height >= item.rect.width * item.rect.height / 2
        }
    }

    /// Whether the item's mosaic is still in the document.
    func isApplied(_ id: UUID, in annotations: [ScreenshotAnnotation]) -> Bool {
        guard let mosaic = mosaics[id] else { return false }
        return annotations.contains { $0.id == mosaic }
    }

    /// What ticking or unticking an item does to the document.
    enum Change: Equatable {
        case add([Item])
        case remove(Set<UUID>)
        case none
    }

    /// Covers the item, or uncovers it when its mosaic is there.
    func toggle(_ id: UUID, in annotations: [ScreenshotAnnotation]) -> Change {
        guard let item = items.first(where: { $0.id == id }) else { return .none }
        if isApplied(id, in: annotations), let mosaic = mosaics[id] { return .remove([mosaic]) }
        return .add([item])
    }

    /// Covers every item in the region that is not covered yet.
    func applyAll(in crop: CGRect?, annotations: [ScreenshotAnnotation]) -> Change {
        let pending = visibleItems(in: crop).filter { !isApplied($0.id, in: annotations) }
        return pending.isEmpty ? .none : .add(pending)
    }

    /// Remembers the mosaics added for `items`, in the same order.
    mutating func record(_ annotationIDs: [UUID], for added: [Item]) {
        for (item, mosaic) in zip(added, annotationIDs) { mosaics[item.id] = mosaic }
    }

    /// The panel's rows for the region; nil when it has nothing to show.
    func panelState(crop: CGRect?, annotations: [ScreenshotAnnotation]) -> ScreenshotSensitiveInfoPanel.State? {
        guard !isDismissed, status == .done else { return nil }
        let visible = visibleItems(in: crop)
        guard !visible.isEmpty else { return nil }
        return .init(rows: visible.map { item in
            .init(id: item.id, kind: item.finding.kind, text: item.finding.maskedText,
                  applied: isApplied(item.id, in: annotations))
        })
    }
}
