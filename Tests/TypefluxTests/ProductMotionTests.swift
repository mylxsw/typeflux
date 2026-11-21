import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import OpieMenu
@testable import Typeflux

@Suite("Product motion capture", .serialized, .exclusiveUIState)
@MainActor
struct ProductMotionTests {
    @Test func renderMotionScenes() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_PRODUCT_MOTION"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let oldLanguage = AppLocalization.shared.language
        let oldKeychain = KeychainTokenStore.useInMemoryStoreForTesting
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        defer { AppLocalization.shared.setLanguage(oldLanguage); KeychainTokenStore.useInMemoryStoreForTesting = oldKeychain }
        let capture = ProductMotionCapture()
        defer { capture.close() }
        let selected = Set((ProcessInfo.processInfo.environment["TYPEFLUX_MOTION_SCENES"] ?? "").split(separator: ",").map(String.init))
        if selected.isEmpty || selected.contains("voice") { try await voice(capture, directory: directory) }
        if selected.isEmpty || selected.contains("chat") { try await chat(capture, directory: directory) }
        if selected.isEmpty || selected.contains("ring") { try await ring(capture, directory: directory) }
        if selected.isEmpty || selected.contains("clipboard") { try await clipboard(capture, directory: directory) }
        if selected.isEmpty || selected.contains("screenshot") { try await screenshot(capture, directory: directory) }
        if selected.isEmpty || selected.contains("recording") { try await recording(capture, directory: directory) }
        try await workflows(capture, directory: directory, selected: selected)
        if selected.isEmpty || selected.contains("translation") { try await translation(capture, directory: directory) }
    }

    private func ring(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let features: [RingFeature] = [.dictation, .ask, .translate, .screenshot, .screenshotText, .clipboard]
        let items = features.map { OpieMenuItem(id: $0.rawValue, title: $0.title, icon: .systemSymbol($0.symbol)) }
        let menu = RadialMenuView(frame: CGRect(x: 0, y: 0, width: 620, height: 620), items: items, centerTitle: "Typeflux")
        menu.style = .frosted
        menu.freezesPointerForPreview = true
        let surface = RadialMenuSurface(frame: CGRect(x: 0, y: 0, width: 620, height: 620), menu: menu)
        surface.frame.origin = CGPoint(x: 250, y: 60)
        capture.stage.addSubview(surface)
        menu.prepareGraphics(); menu.prepareForOpening()
        surface.isHidden = true
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let result = capture.mount(AskLauncherView(model: f.model, onDismiss: {}), size: CGSize(width: AskMetrics.launcherWidth, height: 600))
        result.isHidden = true
        let pointer = NSImageView(image: NSCursor.arrow.image)
        pointer.frame.size = CGSize(width: 24, height: 32)
        capture.stage.addSubview(pointer); pointer.isHidden = true
        var opened = false, clicked = false, didSelect = false
        menu.onSelect = { _ in
            didSelect = true
            menu.animateOut { surface.isHidden = true; pointer.isHidden = true; result.isHidden = false }
        }
        try await capture.record("ring", duration: 7, directory: directory) { t in
            if t > 0.35 && !opened { opened = true; surface.isHidden = false; menu.animateIn() }
            if t > 1 && t < 4.2 {
                let angle: Double = t < 2.9 ? (.pi / 2) - (t - 1) * 1.4 : .pi / 6
                let point = CGPoint(x: 310 + cos(angle)*140, y: 310 + sin(angle)*140)
                menu.updateHover(at: point)
                pointer.isHidden = false
                pointer.frame.origin = CGPoint(x: 250+point.x, y: 60+point.y-28)
            }
            if t > 4.2 && !clicked {
                clicked = true
                let point = CGPoint(x: 310+cos(Double.pi/6)*140, y: 310+sin(Double.pi/6)*140)
                menu.beginPointerPress(at: point); menu.releasePointerPress(at: point)
            }
        }
        #expect(didSelect)
        menu.stopMotion()
    }
}
