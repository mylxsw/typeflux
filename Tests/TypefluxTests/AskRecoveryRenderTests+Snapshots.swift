import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import Vision

extension AskRecoveryRenderTests {
    func readable(_ text: String) -> String {
        // OCR inserts spaces between wrapped lines and Chinese words. Ignore those
        // differences and curly/straight quotes while still requiring every word.
        // Vision also reads 并 as 井 and drops a sentence's final full stop at a wrap.
        text.replacingOccurrences(of: "井", with: "并").replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    func expectOneReturnButton(_ text: String, active: Bool, language: AppLanguage = .english) {
        let label = readable(localized("ask.recovery.close", language: language))
        let guidance = ["ask.recovery.unknownBody", "ask.recovery.checkBody",
                        active ? "ask.recovery.endBody" : "ask.recovery.followUpBody"]
        let mentionsInGuidance = guidance.reduce(0) { count, key in
            count + readable(localized(key, language: language)).components(separatedBy: label).count - 1
        }
        #expect(readable(text).components(separatedBy: label).count - 1 == mentionsInGuidance + 1)
    }

    func localized(_ key: String, language: AppLanguage = .english) -> String {
        let bundle = language.bundleLocalizationCandidates.compactMap {
            Bundle.module.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))
        }.first ?? Bundle.module
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @discardableResult
    func renderConversation(_ model: AskConversationModel, name: String, dark: Bool = false,
                            language: AppLanguage = .english, size: NSSize) async throws -> String {
        func content() -> some View {
            AskConversationView(model: model)
                .environment(\.askGlassMaterialOverride, .opaque)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(AskTheme.surface)
        }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content())
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        // The transcript reveals after two queued scroll-restoration passes.
        // Do not own the global language or window focus while those passes run.
        try await Task.sleep(for: .milliseconds(400))
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        hosting.rootView = content()
        model.objectWillChange.send()
        return try snapshot(hosting, name: name, language: language)
    }

    @discardableResult
    func render(_ view: some View, name: String, dark: Bool = false,
                language: AppLanguage = .english,
                size: NSSize = .init(width: 650, height: 480)) throws -> String {
        // Keep global localization changes inside one MainActor job. Other test
        // suites can change the language or window focus whenever an async test yields.
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        return try snapshot(hosting, name: name, language: language)
    }

    func snapshot(_ hosting: NSView, name: String, language: AppLanguage) throws -> String {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        // Explicit Retina density keeps small native labels legible both in the
        // exported fixtures and to Vision, independent of the runtime display.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(hosting.bounds.width * 2),
            pixelsHigh: Int(hosting.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Vision prioritizes the first language; English-first recognition misses
        // entire Chinese labels even when zh-Hans is present as a fallback.
        request.recognitionLanguages = language == .simplifiedChinese ? ["zh-Hans", "en-US"] : ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
