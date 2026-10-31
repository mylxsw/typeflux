import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
    @Test func `native provider and test buttons drive the same persisted setup`() async throws {
        try await fixture { settings, session, manager, _, _ in
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                let free = OnboardingStrings.text("provider.free.title", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(free, in: host) }
                try Controls.button(free, in: host).press()
                #expect(session.speechModel.selectedProvider == .freeModel)
                #expect(settings.sttProvider == .freeModel)
                let local = OnboardingStrings.text("provider.local.title", table: "OnboardingSpeech")
                try Controls.button(local, in: host).press()
                manager.available = false
                session.speechModel.objectWillChange.send()
                let download = OnboardingStrings.text("local.download", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(download, in: host) }
                try Controls.button(download, in: host).press()
                try await Controls.wait { manager.available }
                #expect(session.speechModel.canContinue == false)
                session.currentStep = .llm
                let openAI = OnboardingStrings.text("provider.openai.title", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(openAI, in: host) }
                try Controls.button(openAI, in: host).press()
                #expect(session.llmModel.selectedProvider == .remote(.openAI))
                session.llmModel.apiKey = "fixture"
                try await Controls.wait { session.llmModel.validationStatus == .valid }
                let test = OnboardingStrings.text("action.testConnection", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(test, in: host) }
                try Controls.button(test, in: host).press()
                try await Controls.wait {
                    if case .success = session.llmModel.testStatus { return true }
                    return false
                }
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference) != nil)
            }
        }
    }
}

extension OnboardingSpeechLLMTests {
    func captureMenus(_ session: OnboardingViewModel, host: NSView, suffix: String) async throws {
        session.currentStep = .speech
        session.speechModel.selectProvider(.localModel)
        try await Task.sleep(for: .milliseconds(100))
        try captureNativeMenu(in: host, index: 0, name: "speech-model-menu-\(suffix)")
        session.currentStep = .llm
        session.llmModel.selectProvider(.remote(.openAI))
        session.llmModel.apiKey = "fixture"
        try await Controls.wait { session.llmModel.validationStatus == .valid }
        try await Task.sleep(for: .milliseconds(100))
        // The first menu is the provider list's More menu; the second is the model menu.
        try captureNativeMenu(in: host, index: 1, name: "llm-model-menu-\(suffix)")
        try captureNativeMenu(in: host, index: 0, name: "llm-more-menu-\(suffix)")
    }

    private func captureNativeMenu(in host: NSView, index: Int, name: String) throws {
        @MainActor func buttons(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let menus = buttons(host)
        #expect(menus.count > index, "The rendered page must expose its native menu")
        guard menus.count > index else { return }
        let button = menus[index]
        let menu = try #require(button.menu)
        button.scrollToVisible(button.bounds)
        menu.delegate?.menuNeedsUpdate?(menu)
        var captureError: Error?
        var captured = false
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                do {
                    try self.snapshotMenuWindows(host, name: name)
                    captured = true
                } catch {
                    captureError = error
                }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        timer.invalidate()
        if let captureError { throw captureError }
        #expect(captured, "The menu must remain open until the native capture finishes")
    }

    private func snapshotMenuWindows(_ host: NSView, name: String) throws {
        let window = try #require(host.window)
        let origin = window.convertToScreen(host.convert(host.bounds, to: nil)).origin
        let menuWindows = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue
        }
        #expect(!menuWindows.isEmpty, "A native popup window must be visible")
        @MainActor func compose() throws -> NSImage {
            let image = NSImage(size: host.bounds.size)
            image.lockFocus()
            defer { image.unlockFocus() }
            @MainActor func draw(_ view: NSView, at point: NSPoint) throws {
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                bitmap.draw(in: NSRect(origin: point, size: view.bounds.size))
            }
            try draw(host, at: .zero)
            for popup in menuWindows {
                guard let content = popup.contentView else { continue }
                let frame = popup.convertToScreen(content.convert(content.bounds, to: nil))
                try draw(content, at: NSPoint(x: frame.minX - origin.x, y: frame.minY - origin.y))
            }
            return image
        }
        let image = try compose()
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_GUL303_SNAPSHOTS"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
    }
}
