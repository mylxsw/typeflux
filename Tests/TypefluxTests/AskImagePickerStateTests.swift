import Testing
@testable import Typeflux

struct AskImagePickerStateTests {
    @Test(arguments: [true, false], [true, false])
    func loadingNeverOffersConfiguration(failed: Bool, hasChoices: Bool) {
        let state = AskImagePickerState(hasChoices: hasChoices, loading: true, catalogFailed: failed, loggedIn: true)
        #expect(state.content == (hasChoices ? .choices : .loading))
        #expect(!state.offersSettings)
        #expect(!state.offersRetry)
        #expect(!state.showsCloudFailure)
    }

    @Test func fetchFailureOffersRetryInsteadOfSettings() {
        let state = AskImagePickerState(hasChoices: false, loading: false, catalogFailed: true, loggedIn: true)
        #expect(state.content == .failed)
        #expect(state.offersRetry)
        #expect(!state.offersSettings)
        #expect(!state.canContinue(candidate: "local", providers: providers, busy: false))
    }

    @Test func confirmedEmptyCatalogOffersSettings() {
        let state = AskImagePickerState(hasChoices: false, loading: false, catalogFailed: false, loggedIn: true)
        #expect(state.content == .empty)
        #expect(state.offersSettings)
        #expect(!state.offersRetry)
    }

    @Test(arguments: [true, false], [true, false])
    func localModelsRemainUsableDuringCloudFailureOrRefresh(failed: Bool, loading: Bool) {
        let state = AskImagePickerState(hasChoices: true, loading: loading, catalogFailed: failed, loggedIn: true)
        #expect(state.content == .choices)
        #expect(state.showsCloudFailure == (failed && !loading))
        #expect(state.canContinue(candidate: "local", providers: providers, busy: false))
        #expect(state.canContinue(candidate: "cloud:vision", providers: providers, busy: false) == (!failed && !loading))
        #expect(!state.canContinue(candidate: "missing", providers: providers, busy: false))
        #expect(!state.canContinue(candidate: "local", providers: providers, busy: true))
        #expect(!state.offersSettings)
    }

    @Test(arguments: [true, false], [true, false])
    func expiredSessionOffersLoginEvenWithLocalModels(failed: Bool, loading: Bool) {
        let state = AskImagePickerState(hasChoices: true, loading: loading, catalogFailed: failed, loggedIn: false)
        #expect(state.content == .signedOut)
        #expect(!state.offersSettings)
        #expect(!state.offersRetry)
        #expect(!state.canContinue(candidate: "local", providers: providers, busy: false))
    }

    private var providers: [RegisteredProvider] {
        [.init(id: "typefluxCloud", name: "Typeflux Cloud", remote: .typefluxCloud, models: [.init(id: "vision", name: "Vision", reference: "cloud:vision")]),
         .init(id: "local", name: "Local", baseURL: "https://example.invalid/v1", models: [.init(id: "local", name: "Local", reference: "local")])]
    }
}
