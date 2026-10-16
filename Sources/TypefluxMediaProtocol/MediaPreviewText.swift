import Foundation

public enum MediaPreviewText {
    /// The index may normalize line breaks; retain UTF-16 offsets back to the actual PDF text.
    public static func ranges(in text: String, passage: String) -> [NSRange] {
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let direct = (text as NSString).range(of: passage, options: [.caseInsensitive, .diacriticInsensitive])
        if direct.location != NSNotFound { return [direct] }
        func compact(_ value: String) -> (String, [Int]) {
            var units: [UInt16] = [], offsets: [Int] = [], position = 0
            for scalar in value.unicodeScalars {
                let encoded = Array(String(scalar).utf16)
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    units += encoded; offsets += encoded.indices.map { position + $0 }
                }
                position += encoded.count
            }
            return (String(decoding: units, as: UTF16.self), offsets)
        }
        let (source, offsets) = compact(text), (needle, _) = compact(passage)
        guard !needle.isEmpty else { return [] }
        let range = (source as NSString).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound, NSMaxRange(range) <= offsets.count else { return [] }
        let start = offsets[range.location], end = offsets[NSMaxRange(range) - 1] + 1
        return [NSRange(location: start, length: end - start)]
    }
}
