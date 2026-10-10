import CoreGraphics
import Foundation
import Vision

/// Vision's translational image registration, for the vertical shift between two frames.
struct VisionScrollOffsetEstimator: ScrollOffsetEstimating {
    func verticalShifts(from previous: CGImage, to current: CGImage) -> [Int] {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current)
        do {
            try VNImageRequestHandler(cgImage: previous).perform([request])
        } catch {
            return []
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return [] }
        return Self.shifts(translationY: observation.alignmentTransform.ty)
    }

    /// Vision measures from the bottom-left corner, so which way is up depends on how the result is
    /// read; both directions are proposed and the row check keeps the one that lines up.
    static func shifts(translationY: CGFloat) -> [Int] {
        guard translationY.isFinite else { return [] }
        let shift = Int(translationY.rounded())
        return shift == 0 ? [0] : [shift, -shift]
    }
}
