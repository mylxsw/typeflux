import Foundation

// Build-time only. Runtime search consumes the generated romanizations.
let input = FileHandle.standardInput.readDataToEndOfFile()
let words = try JSONDecoder().decode([String].self, from: input)
var output: [String: [String]] = [:]
for word in words {
    let buffer = NSMutableString(string: word) as CFMutableString
    CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false)
    CFStringTransform(buffer, nil, kCFStringTransformStripDiacritics, false)
    let syllables = (buffer as String).lowercased().split(whereSeparator: { !$0.isASCII || !$0.isLetter })
    let spelling = syllables.joined()
    let initials = syllables.compactMap(\.first).map(String.init).joined()
    output[word] = [spelling, initials.count > 1 ? initials : ""].filter { !$0.isEmpty }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(output))
