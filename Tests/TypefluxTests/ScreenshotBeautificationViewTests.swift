import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotBeautificationViewTests: XCTestCase {
    private func source(width: Int = 80, height: Int = 40) -> CGImage {
        ScreenCaptureTestSupport.image(width: width, height: height, gray: 0.1)
    }

    func testPanelFitsCommonScreenSizes() {
        XCTAssertEqual(ScreenshotBeautificationView.size(for: CGSize(width: 1512, height: 982)),
                       CGSize(width: 960, height: 720))
        XCTAssertEqual(ScreenshotBeautificationView.size(for: CGSize(width: 1024, height: 768)),
                       CGSize(width: 960, height: 696))
    }

    private func perform(_ action: String, on object: NSObject) throws {
        let selector = NSSelectorFromString(action)
        XCTAssertTrue(object.responds(to: selector))
        guard object.responds(to: selector) else { return }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Action.self)
        let handled = implementation(object, selector)
        // SwiftUI sliders can report false after a successful increment. Assert their state below.
        if action != "accessibilityPerformIncrement" { XCTAssertTrue(handled, action) }
    }

    func testPaletteSlidersToggleAndActionsWorkThroughNativeAccessibility() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let model = ScreenshotBeautificationPreview(source: source(), scale: 1, settings: .init())
        var applied = 0, cancelled = 0
        let host = NSHostingView(rootView: ScreenshotBeautificationView(model: model,
            cancel: { cancelled += 1 }, apply: { applied += 1 }))
        let window = makeWindow(host, appearance: .darkAqua)
        defer { window.close() }
        func control(_ label: String, action: String = "accessibilityPerformPress") -> NSObject? {
            SettingsBehaviorTestSupport.elements(in: window).first {
                ($0.label == label || $0.value("accessibilityTitle") as? String == label) &&
                    $0.object.responds(to: NSSelectorFromString(action))
            }?.object
        }
        let firstLabel = L("screenshot.beautify.background.transparent")
        try await SettingsBehaviorTestSupport.wait { control(firstLabel) != nil }
        for background in ScreenshotBeautification.Background.availableCases {
            let label = L("screenshot.beautify.background.\(background.rawValue)")
            try perform("accessibilityPerformPress", on: XCTUnwrap(control(label)))
            try await SettingsBehaviorTestSupport.wait {
                model.settings.background == background && model.settings.isEnabled
            }
            XCTAssertEqual(model.image?.width, 176)
        }
        for (key, value) in [("padding", \ScreenshotBeautification.padding),
                             ("radius", \.cornerRadius), ("shadow", \.shadow)] {
            try perform("accessibilityPerformPress", on: XCTUnwrap(control(L("screenshot.beautify.reset"))))
            try await SettingsBehaviorTestSupport.wait { !model.settings.isEnabled }
            XCTAssertEqual(model.image?.width, 80)
            let initial = model.settings[keyPath: value]
            let action = "accessibilityPerformIncrement"
            let label = L("screenshot.beautify.\(key)")
            try perform(action, on: XCTUnwrap(control(label, action: action)))
            try await SettingsBehaviorTestSupport.wait {
                model.settings[keyPath: value] > initial && model.settings.isEnabled
            }
        }
        try await pressSwitch(in: window)
        try await SettingsBehaviorTestSupport.wait { !model.settings.isEnabled }
        try perform("accessibilityPerformPress", on: XCTUnwrap(control(L("screenshot.beautify.apply"))))
        try perform("accessibilityPerformPress", on: XCTUnwrap(control(L("screenshot.beautify.cancel"))))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(cancelled, 1)
    }

    private func pressSwitch(in window: NSWindow) async throws {
        // Wait for SwiftUI to project the slider's auto-enable change into the native control.
        try await SettingsBehaviorTestSupport.wait {
            window.contentView?.layoutSubtreeIfNeeded()
            return SettingsBehaviorTestSupport.elements(in: window).contains {
                $0.role == NSAccessibility.Role.checkBox.rawValue &&
                    ($0.value("accessibilityValue") as? NSNumber)?.boolValue == true
            }
        }
        let elements = SettingsBehaviorTestSupport.elements(in: window)
        XCTAssertTrue(elements.contains { $0.label == L("screenshot.beautify.enabled") })
        let toggle = try XCTUnwrap(elements.first { $0.role == NSAccessibility.Role.checkBox.rawValue },
            "Missing native switch: \(elements.map { ($0.role, $0.label) })")
        if let nativeSwitch = toggle.object as? NSSwitch {
            nativeSwitch.performClick(nil)
        } else {
            try perform("accessibilityPerformPress", on: toggle.object)
        }
    }

    func testInvalidPreviewShowsAnAccessibleErrorAndDisablesApply() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let model = ScreenshotBeautificationPreview(source: source(), scale: 0,
            settings: ScreenshotBeautification(isEnabled: true))
        let host = NSHostingView(rootView: ScreenshotBeautificationView(model: model, cancel: {}, apply: {}))
        let window = makeWindow(host, appearance: .aqua)
        defer { window.close() }
        try await SettingsBehaviorTestSupport.wait {
            SettingsBehaviorTestSupport.elements(in: window).contains {
                $0.text == L("screenshot.beautify.failed")
            }
        }
        let apply = try XCTUnwrap(SettingsBehaviorTestSupport.elements(in: window).first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("screenshot.beautify.apply")
        })
        XCTAssertEqual(apply.value("isAccessibilityEnabled") as? Bool, false)
        try capture(host, name: "beautify-error")
    }

    func testPreviewRendersInEveryLanguageAndBothSystemAppearances() throws {
        let screenshot = try sampleScreenshot()
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let model = ScreenshotBeautificationPreview(source: screenshot, scale: CGFloat(screenshot.width) / 680,
                    settings: ScreenshotBeautification(isEnabled: true))
                let host = NSHostingView(rootView: ScreenshotBeautificationView(model: model, cancel: {}, apply: {}))
                let window = makeWindow(host, appearance: name)
                defer { window.close() }
                XCTAssertEqual(host.fittingSize, ScreenshotBeautificationView.size)
                try capture(host, name: "beautify-\(language.rawValue)-\(name.rawValue)")
                if language == .simplifiedChinese && name == .darkAqua {
                    model.settings.background = .transparent
                    try capture(host, name: "beautify-transparent")
                }
            }
        }
    }

    private func makeWindow(_ host: NSView, appearance: NSAppearance.Name) -> NSWindow {
        host.frame = CGRect(origin: .zero, size: ScreenshotBeautificationView.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_BEAUTIFICATION_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func sampleScreenshot() throws -> CGImage {
        let size = CGSize(width: 680, height: 360)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let lines: [(String, NSColor)] = [
            ("// A little space makes a difference.", NSColor(white: 0.55, alpha: 1)),
            ("let screenshot = capture(region)", .white),
            ("", .white),
            ("screenshot.beautify(", .white),
            ("    background: .mint,", .systemMint),
            ("    padding: 48,", .systemMint),
            ("    cornerRadius: 12", .systemMint),
            (")", .white)
        ]
        for (index, line) in lines.enumerated() {
            (line.0 as NSString).draw(at: CGPoint(x: 36, y: 270 - index * 28),
                withAttributes: [.font: font, .foregroundColor: line.1])
        }
        ("Typeflux  /  Screenshot" as NSString).draw(at: CGPoint(x: 36, y: 322),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                             .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        return try XCTUnwrap(context.makeImage())
    }
}
