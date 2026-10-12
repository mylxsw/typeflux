import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI component gallery", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIGalleryTests {
    // SwiftPM's async runner exits early if further renders follow a native
    // menu/window lifecycle. Run this opt-in check in its own test process.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_UI_GALLERY_LIVE"] == "1"))
    func `dev menu opens reuses and restyles gallery`() async throws {
        _ = NSApplication.shared
        var activations = 0
        let controller = TypefluxGalleryWindowController(activateApplication: { activations += 1 })
        let menu = DevLauncher.makeMenu(gallery: controller)
        #expect(menu.title == "Dev")
        let item = try #require(menu.submenu?.items.first)
        #expect(item.title == "Component Gallery")
        #expect(try NSApp.sendAction(#require(item.action), to: item.target, from: item))
        let window = try #require(controller.window)
        defer { window.orderOut(nil); window.close() }
        #expect(window.isVisible)
        #expect(activations == 1)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute) }
        try await Task.sleep(for: .milliseconds(100))
        let styleSegment = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
            $0.label == "Liquid Glass" && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        })
        activateSegment(styleSegment)
        try await SettingsBehaviorTestSupport.wait { controller.style == .liquidGlass }
        let appearanceSegment = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
            $0.label == "Dark" && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        })
        activateSegment(appearanceSegment)
        try await SettingsBehaviorTestSupport.wait { controller.appearance == .dark }
        for style in InterfaceStyle.allCases {
            for appearance in [ColorScheme.light, .dark] {
                controller.style = style
                controller.appearance = appearance
                controller.showGallery()
                try await Task.sleep(for: .milliseconds(50))
                #expect(controller.window === window)
                #expect(window.appearance?
                    .bestMatch(from: [.aqua, .darkAqua]) == (appearance == .dark ? .darkAqua : .aqua))
                #expect(window.contentView?.fittingSize.width ?? 0 > 0)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"] {
                    let file = URL(fileURLWithPath: directory)
                        .appendingPathComponent("gallery-live-\(style.rawValue)-\(appearance == .dark ? "dark" : "light").png")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
                    try capture.run()
                    capture.waitUntilExit()
                    #expect(capture.terminationStatus == 0)
                }
            }
        }
        window.close()
        controller.showGallery()
        #expect(controller.window === window)
        #expect(window.isVisible)
        #expect(activations == 6)
    }

    private func activateSegment(_ element: SettingsBehaviorTestSupport.Element) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(element.object.method(for: selector), to: Press.self)
        // AppKit segments can return false after updating their binding. Check
        // the visible state through the controller rather than this return value.
        _ = action(element.object, selector)
    }

    @Test func `gallery renders every combination and accessibility fallback`() async throws {
        let configured = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"]
        let directory = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if configured == nil {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                let view = TypefluxGalleryView(style: .constant(style), appearance: .constant(dark ? .dark : .light),
                                               labels: TypefluxGalleryWindowController.labels)
                try await TypefluxUISnapshot.render(view, size: NSSize(width: 1000, height: 1180),
                                                    style: style, dark: dark,
                                                    file: directory
                                                        .appendingPathComponent(
                                                            "gallery-\(style.rawValue)-\(dark ? "dark" : "light").png"
                                                        ))
                for reduced in [false, true] {
                    for contrasted in [false, true] {
                        #expect(GlassBackground.effectiveMaterial(.liquidGlass, reduceTransparency: reduced,
                                                                 increasedContrast: contrasted)
                            == (reduced || contrasted ? .opaque : .liquidGlass))
                        let host = NSHostingView(rootView: view)
                        host.appearance = NSAppearance(named: contrasted
                            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                            : (dark ? .darkAqua : .aqua))
                        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 1180)
                        host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.width > 0)
                    }
                }
            }
        }
    }
}
