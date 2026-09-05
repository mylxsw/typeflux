import Foundation
import Testing
@testable import Typeflux

@Suite("Editor content evidence")
struct TextDeliveryContentTests {
    @Test(arguments: [true, false])
    func placeholderIsNotDocumentContent(hasCharacterCount: Bool) {
        let before = TextDeliveryContent.value(
            raw: "\n\nWork with ChatGPT", characterCount: hasCharacterCount ? 0 : nil,
            rangedText: nil, placeholder: "Work with ChatGPT", selection: CFRange(location: 0, length: 0)
        )
        #expect(before == "")
        #expect(TextDeliveryEvidence.confirms(text: "Beia", before: before,
            range: CFRange(location: 0, length: 0), after: "Beia"))
    }

    @Test func rangeTextOverridesDecoratedValueWithoutTrimmingRealWhitespace() {
        let content = TextDeliveryContent.value(
            raw: "Label\n  abc\n", characterCount: 6, rangedText: "  abc\n",
            placeholder: nil, selection: CFRange(location: 2, length: 0)
        )
        #expect(content == "  abc\n")
        #expect(TextDeliveryEvidence.confirms(text: "X", before: content,
            range: CFRange(location: 3, length: 0), after: "  aXbc\n"))
        #expect(!TextDeliveryEvidence.confirms(text: "X", before: content,
            range: CFRange(location: 3, length: 0), after: "X"))
    }

    @Test func actualTextEqualToPlaceholderRemainsRealText() {
        #expect(TextDeliveryContent.value(raw: "hello", characterCount: 5, rangedText: nil,
            placeholder: "hello", selection: CFRange(location: 0, length: 0)) == "hello")
        #expect(TextDeliveryContent.value(raw: "hello", characterCount: nil, rangedText: nil,
            placeholder: "hello", selection: CFRange(location: 5, length: 0)) == "hello")
    }

    @Test func missingMetadataDoesNotInventEmptyContent() {
        #expect(TextDeliveryContent.value(raw: "Work with ChatGPT", characterCount: nil,
            rangedText: nil, placeholder: nil, selection: CFRange(location: 0, length: 0)) == "Work with ChatGPT")
        #expect(TextDeliveryContent.value(raw: nil, characterCount: nil, rangedText: nil,
            placeholder: nil, selection: nil) == nil)
        #expect(TextDeliveryContent.value(raw: "label", characterCount: 3, rangedText: nil,
            placeholder: nil, selection: nil) == nil)
    }

    @Test func utf16CharacterCountAndUnchangedValueRemainStrict() {
        let content = TextDeliveryContent.value(raw: "😀", characterCount: 2, rangedText: nil,
            placeholder: nil, selection: CFRange(location: 0, length: 2))
        #expect(content == "😀")
        #expect(!TextDeliveryEvidence.confirms(text: "😀", before: content,
            range: CFRange(location: 0, length: 2), after: "😀"))
        #expect(TextDeliveryContent.value(raw: "abc", characterCount: -1, rangedText: nil,
            placeholder: nil, selection: nil) == nil)
    }
}
