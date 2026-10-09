import Testing
@testable import Typeflux

@Suite("Ask reference editor", .exclusiveUIState)
struct AskReferenceEditorTests {
    @Test func suggestionsMatchTheSelectionBarQuestions() {
        #expect(AskReferenceEditor.suggestions == [.explain, .translate])
        #expect(AskReferenceEditor.suggestions.map(\.question)
            == [L("ask.references.explain"), L("ask.references.translate")])
        #expect(AskReferenceEditor.suggestions.allSatisfy { !$0.question.isEmpty })
    }

    @Test func budgetCountsExcerptAndQuestionBytes() {
        var reference = AskReference(messageId: "m", text: "abcd")
        #expect(!AskReferenceEditor.exceedsBudget(reference, budget: 4))
        reference.question = "e"
        #expect(AskReferenceEditor.exceedsBudget(reference, budget: 4))
        #expect(!AskReferenceEditor.exceedsBudget(reference, budget: 5))
        // UTF-8 bytes, not characters: each CJK character is three bytes.
        let cjk = AskReference(messageId: "m", text: "解释")
        #expect(AskReferenceEditor.exceedsBudget(cjk, budget: 5))
        #expect(!AskReferenceEditor.exceedsBudget(cjk, budget: 6))
    }

    @Test func capsuleStyleHasBothKinds() {
        let primary = AskCapsuleButtonStyle()
        let secondary = AskCapsuleButtonStyle(kind: .secondary)
        #expect(primary.kind == .primary)
        #expect(secondary.kind == .secondary)
    }
}
