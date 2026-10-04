import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite("Ask account card hover")
struct AskAccountCardHoverTests {
    final class Pointer {
        var inside = false
    }

    /// Polls instead of sleeping a fixed time, so a loaded machine only slows the test down.
    /// Concurrent native rendering can occupy MainActor beyond the former 3s limit.
    /// Keep the behavior assertion; allow the scheduled hover task time to run.
    func wait(_ condition: () -> Bool, timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func make(_ pointer: Pointer) -> AskAccountCardHover {
        AskAccountCardHover(openDelay: .milliseconds(60), pollInterval: .milliseconds(20)) { pointer.inside }
    }

    @Test func aQuickPassDoesNotOpenTheCard() async throws {
        // The real delay, so a slow machine cannot stretch the pass past it.
        let hover = AskAccountCardHover(pollInterval: .milliseconds(20)) { false }
        hover.hover(true)
        try await Task.sleep(for: .milliseconds(20))
        hover.hover(false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hover.isPresented)
    }

    @Test func restingOnTheNameOpensItAndLeavingBothClosesIt() async throws {
        let pointer = Pointer()
        let hover = make(pointer)
        hover.hover(true)
        try await wait { hover.isPresented }
        #expect(hover.isPresented)
        #expect(!hover.pinned)
        // Into the card: the name reports an exit but the pointer is still on the card.
        pointer.inside = true
        hover.hover(false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(hover.isPresented)
        // Off the card too.
        pointer.inside = false
        try await wait { !hover.isPresented }
        #expect(!hover.isPresented)
    }

    @Test func returningToTheNameKeepsItOpen() async throws {
        let pointer = Pointer()
        let hover = make(pointer)
        hover.hover(true)
        try await wait { hover.isPresented }
        hover.hover(false)
        hover.hover(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(hover.isPresented)
    }

    @Test func aClickPinsItAndASecondClickCloses() async throws {
        let pointer = Pointer()
        let hover = make(pointer)
        hover.click()
        #expect(hover.isPresented)
        #expect(hover.pinned)
        hover.hover(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(hover.isPresented, "A pinned card ignores the pointer leaving.")
        hover.click()
        #expect(!hover.isPresented)
        #expect(!hover.pinned)
    }

    @Test func clickingAHoverOpenedCardPinsIt() async throws {
        let hover = make(Pointer())
        hover.hover(true)
        try await wait { hover.isPresented }
        hover.click()
        #expect(hover.isPresented)
        #expect(hover.pinned)
    }

    @Test func closingFromOutsideUnpins() {
        let hover = make(Pointer())
        hover.click()
        hover.isPresented = false // The presenter's outside click / Esc.
        #expect(!hover.pinned)
        hover.click()
        #expect(hover.isPresented)
    }
}
