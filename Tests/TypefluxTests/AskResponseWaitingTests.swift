import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask response waiting")
struct AskResponseWaitingTests {
    private func run(status: String = "running") -> AskRun {
        .init(id: "run", deviceId: "device", status: status, steps: 1, updatedAt: Date(),
              tools: [], pending: [], assistantId: "answer")
    }

    private func visible(phase: AskRunPhase? = .working(step: 1), pending: Bool = false,
                         run: AskRun? = nil, messages: [AskMessage] = [],
                         progress: AskStreamProgress? = nil, error: Bool = false) -> Bool {
        AskResponseWaiting.isVisible(phase: phase, pendingSubmission: pending, run: run,
                                     messages: messages, progress: progress, hasError: error)
    }

    @Test func submissionShowsFeedbackBeforeThereIsARun() {
        #expect(visible(pending: true))
        #expect(!visible())
    }

    @Test func followUpIgnoresThePreviousAnswerWhileSubmitting() {
        let answer = AskMessage(id: "answer", role: "assistant", text: "Previous answer", createdAt: Date())
        #expect(visible(pending: true, run: run(status: "completed"), messages: [answer]))
        #expect(!visible(run: run(status: "completed"), messages: [answer]))
    }

    @Test func reasoningAndWhitespaceKeepFeedbackUntilAnswerTextArrives() {
        #expect(visible(run: run()))
        #expect(visible(run: run(), progress: .init(text: " \n", reasoning: "Thinking through the question")))
        #expect(!visible(run: run(), progress: .init(text: "First word")))
    }

    @Test func onlyCurrentAssistantTextHidesFeedback() {
        let old = AskMessage(id: "old-answer", role: "assistant", text: "Earlier step", createdAt: Date())
        let current = AskMessage(id: "answer", role: "assistant", text: "New answer", createdAt: Date())
        #expect(visible(run: run(), messages: [old]))
        #expect(!visible(run: run(), messages: [old, current]))
    }

    @Test(arguments: [AskRunPhase.approval, .needsDecision(step: 1), .pausedCredits(step: 1),
                      .completed(steps: 1), .failed, .cancelled])
    func haltedRunsNeverShowWorkingFeedback(phase: AskRunPhase) {
        #expect(!visible(phase: phase, pending: true, run: run()))
    }

    @Test func errorsAndIdleConversationsHideFeedback() {
        #expect(!visible(phase: nil, pending: true))
        #expect(!visible(pending: true, error: true))
        #expect(!visible(run: run(), error: true))
    }

    @Test func dotsLightInOrderAndGlideAcrossTheLoopBoundary() {
        for dot in 0..<3 {
            let peak = Double(dot) * AskResponseWaiting.stagger
            let own = AskResponseWaiting.opacity(dot: dot, elapsed: peak)
            #expect((0..<3).filter { $0 != dot }.allSatisfy {
                AskResponseWaiting.opacity(dot: $0, elapsed: peak) < own
            })
            for frame in 0..<120 {
                let time = Double(frame) / 60
                let before = AskResponseWaiting.opacity(dot: dot, elapsed: time)
                let after = AskResponseWaiting.opacity(dot: dot, elapsed: time + 1.0 / 60)
                #expect((0.25...0.95).contains(before))
                #expect(abs(after - before) < 0.06)
            }
            let beforeWrap = AskResponseWaiting.opacity(dot: dot, elapsed: AskResponseWaiting.period - 0.001)
            let afterWrap = AskResponseWaiting.opacity(dot: dot, elapsed: AskResponseWaiting.period + 0.001)
            #expect(abs(beforeWrap - afterWrap) < 0.01)
        }
    }
}

@Suite("Ask response waiting rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskResponseWaitingRenderTests {
    @Test func exportAnimationFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_WAITING_FRAMES"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for frame in 0..<42 {
            let view = AskResponseWaitingView().bubble(elapsed: Double(frame) / 30)
                .frame(width: 120, height: 72)
                .background(TypefluxColor.controlBackground.color)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent(String(format: "f%03d.png", frame)))
        }
    }

    @Test func conversationFeedbackTracksStreamAndStop() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskConversation(id: "waiting", title: "Waiting for an answer", revision: 1,
                                    updatedAt: Date(), messages: [
                                        .init(id: "question", role: "user", text: "Explain how this works",
                                              createdAt: Date())
                                    ])
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        let route = try #require(fixture.model.credentials(for: value.id))
        #expect(!fixture.model.showsResponseWaiting)

        value.run = .init(id: "run", deviceId: "device", status: "running", steps: 1,
                          updatedAt: Date(), tools: [], pending: [], assistantId: "answer")
        value.revision += 1
        try await fixture.model.accept(value, route: route)
        #expect(fixture.model.showsResponseWaiting)

        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_WAITING_SNAPSHOTS"] {
            _ = NSApplication.shared
            let view = AskConversationView(model: fixture.model)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.askGlassMaterialOverride, .opaque)
                .environment(\.colorScheme, .dark)
                .frame(width: 1100, height: 740)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("conversation-waiting-dark.png"))
        }

        value.run?.preview = "Here is the answer"
        value.revision += 1
        try await fixture.model.accept(value, route: route)
        #expect(!fixture.model.showsResponseWaiting)

        value.run?.preview = nil
        value.run?.status = "waiting_inference"
        value.revision += 1
        try await fixture.model.accept(value, route: route)
        #expect(!fixture.model.showsResponseWaiting,
                "A parked inference needs a resume decision, not a working indicator")

        value.run?.status = "cancelled"
        value.revision += 1
        try await fixture.model.accept(value, route: route)
        #expect(!fixture.model.showsResponseWaiting)
    }

    @Test func rendersStaticFeedbackInBothAppearances() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let view = AskResponseWaitingView().bubble(elapsed: nil)
                .frame(width: 200, height: 100, alignment: .leading)
                .padding(24)
                .background(TypefluxColor.controlBackground.color)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == 248)
            #expect(image.size.height == 148)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_WAITING_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent(dark ? "waiting-dark.png" : "waiting-light.png"))
            }
        }
    }
}
