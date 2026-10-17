import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxMediaRuntime

extension SemanticPDFPreviewTests {
    // swiftlint:disable:next function_body_length
    func snapshot(_ content: AskFilePreviewContent, hit: AskFileHit, prefix: String) async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for entry in ["mixed", "files"] {
                let state = AskFilePreviewState()
                state.hit = hit; state.content = content; state.detail = content.detail
                let results = AskQuickResults(apps: [], panes: [], files: [hit], moreFiles: false,
                                              groups: [.files], best: .file(0))
                let item = AskFileSearchPlugin.item(hit)
                #expect(item.fileHit?.evidence == hit.evidence)
                let output = AskPluginOutput(body: hit.name, original: "", meta: [], source: "On this Mac",
                                             actions: [], items: [item])
                let display = AskPluginDisplay(title: "Files", symbol: "doc",
                                               phase: .done(.init(mode: .live, title: "Files"), output))
                let host = NSHostingView(rootView: HStack(spacing: 14) {
                    VStack(alignment: .leading) {
                        Text(entry == "mixed" ? "INV-739204" : "f INV-739204").font(.title3).padding()
                        if entry == "mixed" {
                            AskQuickResultsView(results: results, question: "INV-739204", thumbnails: false,
                                                onRun: { _, _ in }, onHighlight: { _ in })
                        } else {
                            AskPluginResultsView(display: display, question: "INV-739204", onMain: {},
                                                 onAction: { _ in }, onAskAI: {}, onHighlight: { _ in })
                        }
                        Spacer()
                    }.frame(width: 560)
                    AskFilePreviewView(state: state).frame(width: 380)
                }.padding(14).background(AskTheme.popoverSurface).environment(\.interfaceStyle, .classic))
                let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 982, height: 548),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: appearance)
                host.sizingOptions = []; panel.contentView = host; panel.orderFront(nil)
                defer { panel.orderOut(nil); panel.close() }
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let label = "\(prefix)-\(entry)-\(appearance == .aqua ? "light" : "dark")"
                let metrics = try snapshotMetrics(png)
                #expect(metrics["regions"] == 1 && (metrics["ink"] ?? 0) > 20)
                #expect(content.imageTextLocated == true ? (metrics["yellow"] ?? 0) > 30 : metrics["yellowTotal"] == 0)
                if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_PDF_PREVIEW_EVIDENCE"] {
                    let output = URL(fileURLWithPath: folder)
                    try png.write(to: output.appendingPathComponent(label + ".png"))
                    try JSONEncoder().encode(metrics).write(to: output.appendingPathComponent(label + ".json"))
                }
            }
        }
    }

    private func snapshotMetrics(_ png: Data) throws -> [String: Int] {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Only the right preview image area; exclude query/results text and the fallback badge.
        let scaleX = CGFloat(image.width) / 982, scaleY = CGFloat(image.height) / 548
        let crop = try #require(image.cropping(to: CGRect(x: 606 * scaleX, y: 100 * scaleY,
                                                         width: 344 * scaleX, height: 280 * scaleY)))
        let boxes = try MediaPreviewOCR.locate(crop, passage: "INV-739204").boxes
        let bitmap = NSBitmapImageRep(cgImage: crop)
        var ink = 0, yellow = 0, total = 0
        for row in 0 ..< bitmap.pixelsHigh {
            for column in 0 ..< bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                let isYellow = red > 0.85 && green > 0.7 && blue < 0.85 && red - blue > 0.15 && green - blue > 0.1
                if isYellow { total += 1 }
                let point = CGPoint(x: (CGFloat(column) + 0.5) / CGFloat(crop.width),
                                    y: 1 - (CGFloat(row) + 0.5) / CGFloat(crop.height))
                if boxes.contains(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }) {
                    if isYellow { yellow += 1 }
                    if max(red, green, blue) < 0.7 { ink += 1 }
                }
            }
        }
        return ["regions": boxes.count, "ink": ink, "yellow": yellow, "yellowTotal": total]
    }
}
