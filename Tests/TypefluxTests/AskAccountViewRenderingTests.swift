import SwiftUI
import Testing
@testable import Typeflux

extension AccountViewRenderingTests {
    @Test func askCardAndFooterRenderAccountStates() async throws {
        for (name, subscription, credits) in Self.states {
            let fixture = Fixture()
            fixture.subscription = subscription
            fixture.credits = credits
            let auth = makeAuth(fixture)
            await auth.refreshSubscription()
            await auth.refreshUsage()
            let card = try await host(AskAccountCard(auth: auth, onOpenAccount: {}, onDismiss: {}),
                                      width: AskAccountCard.width)
            #expect(card.fittingSize.height > 150, "card \(name)")

            let footer = try await host(AskAccountFooterIdentity(auth: auth, name: "Demir Von") {}, width: 230)
            #expect(footer.fittingSize.height > 0)
        }
        let signedOut = makeAuth(Fixture(), signedIn: false)
        let footer = try await host(AskAccountFooterIdentity(auth: signedOut, name: "Typeflux") {}, width: 230)
        #expect(footer.fittingSize.height > 0)
    }
}
