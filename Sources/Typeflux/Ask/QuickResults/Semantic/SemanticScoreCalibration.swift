import Foundation

/// Query-local distribution calibration changes ordering only. Absolute answerability gates remain independent.
/// Each file contributes once per segment class, so adding chunks to a book cannot move the mean.
struct SemanticScoreCalibration {
    enum Bucket: Int, CaseIterable, Hashable {
        case text, cjkText, audio, image, video

        init(modality: SemanticMediaPriority, embedding: SemanticMediaInput.Kind?, script: Int) {
            if embedding == .audio || modality == .audio {
                self = .audio
            } else if modality == .video {
                self = .video
            } else if modality == .image {
                self = .image
            } else {
                self = script == 1 ? .cjkText : .text
            }
        }
    }

    private struct Key: Hashable { var path: String; var bucket: Bucket }
    private var maxima: [Key: Double] = [:]
    private var sums = [Double](repeating: 0, count: Bucket.allCases.count)
    private var squares = [Double](repeating: 0, count: Bucket.allCases.count)
    private var counts = [Int](repeating: 0, count: Bucket.allCases.count)

    mutating func observe(path: String, bucket: Bucket, cosine: Double) {
        guard cosine.isFinite else { return }
        let key = Key(path: path, bucket: bucket), old = maxima[key]
        guard old == nil || cosine > old! else { return }
        sums[bucket.rawValue] += cosine - (old ?? 0)
        squares[bucket.rawValue] += cosine * cosine - (old ?? 0) * (old ?? 0)
        if old == nil {
            counts[bucket.rawValue] += 1
        }
        maxima[key] = cosine
    }

    func adjustment(_ bucket: Bucket, cosine: Double) -> Double {
        let count = counts[bucket.rawValue], total = counts.reduce(0, +)
        guard count > 0, count < total else { return 0 }
        let sharedMean = sums.reduce(0, +) / Double(total), mean = sums[bucket.rawValue] / Double(count)
        let sharedVariance = max(0.0004, squares.reduce(0, +) / Double(total) - sharedMean * sharedMean)
        let variance = max(0, squares[bucket.rawValue] / Double(count) - mean * mean)
        // Four shared observations shrink tiny classes toward the global distribution. Keep a
        // 0.02 standard-deviation floor. These scores order candidates; raw cosine gates rejection.
        let shrunkMean = (sums[bucket.rawValue] + 4 * sharedMean) / Double(count + 4)
        let shrunkVariance = (Double(count) * variance + 4 * sharedVariance) / Double(count + 4)
        let calibrated = sharedMean + (cosine - shrunkMean) * sqrt(sharedVariance / max(0.0004, shrunkVariance))
        return 0.55 * (max(0, min(1, calibrated)) - cosine)
    }

    /// A coarse script marker, not language identification. Keep it in sync with the SQLite fallback
    /// trigger so older writers and rollback/re-upgrade retain compatible search metadata.
    static func script(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if (0x3040 ... 0x30FF).contains(scalar.value) || (0x3400 ... 0x9FFF).contains(scalar.value)
                || (0xAC00 ... 0xD7AF).contains(scalar.value) || (0x20000 ... 0x2FA1F).contains(scalar.value) {
                count += 1
                if count == 2 {
                    return 1
                }
            }
        }
        return 0
    }
}
