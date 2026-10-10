import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// The panel's lazy list only builds rows in view, so each row is also drawn on its own:
/// collapsed and selected, with and without its file, before and after media loads.
final class ClipboardRowRenderingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardRowRenderingTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testEveryRowDrawsInEveryState() async throws {
        let entries = ClipboardTestSupport.allKindsEntries(in: directory)
        for missing in [false, true] {
            for selected in [false, true] {
                let hosts = entries.enumerated().map { index, entry in
                    NSHostingView(rootView: ClipboardPanelRow(
                        entry: entry, index: index, isSelected: selected, isHovered: !selected,
                        isMissing: missing && (entry.imagePath != nil || !entry.filePaths.isEmpty),
                        number: selected ? index + 1 : nil
                    ).frame(width: ClipboardPanelView.width - 16))
                }
                for host in hosts {
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    try draw(host)
                }
                // Thumbnails, durations and waveforms arrive asynchronously; draw the loaded state.
                try await Task.sleep(for: .milliseconds(500))
                for host in hosts {
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    try draw(host)
                }
            }
        }
    }

    /// Rows keep one height whether or not they are selected, so moving the selection never
    /// re-lays out the list.
    @MainActor
    func testSelectionDoesNotChangeRowHeight() throws {
        for entry in ClipboardTestSupport.allKindsEntries(in: directory) {
            let heights = [false, true].map { selected in
                let host = NSHostingView(rootView: ClipboardPanelRow(
                    entry: entry, index: 0, isSelected: selected, isHovered: false, isMissing: false
                ).frame(width: ClipboardPanelView.width - 16))
                return host.fittingSize.height
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "\(entry.kind)")
        }
    }

    func testRowsCompareOnlyWhatTheyDraw() {
        let entry = ClipboardTestSupport.entry(.text, text: "same")
        func row(selected: Bool = false, hovered: Bool = false, missing: Bool = false, number: Int? = nil) -> ClipboardPanelRow {
            ClipboardPanelRow(entry: entry, index: 0, isSelected: selected, isHovered: hovered, isMissing: missing, number: number)
        }
        XCTAssertEqual(row(), row())
        XCTAssertNotEqual(row(), row(selected: true))
        XCTAssertNotEqual(row(), row(hovered: true))
        XCTAssertNotEqual(row(), row(missing: true))
        XCTAssertNotEqual(row(), row(number: 1))
        var performed: [ClipboardEntryAction] = []
        let withCallbacks = ClipboardPanelRow(
            entry: entry, index: 0, isSelected: false, isHovered: false, isMissing: false,
            onPerform: { performed.append($0) }
        )
        XCTAssertEqual(withCallbacks, row(), "Callbacks never make a row redraw")
        withCallbacks.onPerform(.paste)
        XCTAssertEqual(performed, [.paste])
    }

    @MainActor
    func testAudioPlayerAndWaveformDraw() async throws {
        let audio = try ClipboardTestSupport.makeAudioFile(named: "voice.wav", in: directory)
        let views: [AnyView] = [
            AnyView(ClipboardAudioPlayerView(url: audio, duration: 1)),
            AnyView(ClipboardAudioPlayerView(url: audio, duration: nil)),
            AnyView(ClipboardWaveformView(url: audio, bars: 30, progress: 0.5, onSeek: { _ in })),
            AnyView(ClipboardWaveformView(url: nil, bars: 0))
        ]
        let hosts = views.map { NSHostingView(rootView: $0.frame(width: 400, height: 48)) }
        for host in hosts {
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 48)
            try draw(host)
        }
        try await Task.sleep(for: .milliseconds(500))
        for host in hosts {
            try draw(host)
        }
    }

    private func draw(_ host: NSView) throws {
        host.layoutSubtreeIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0 else { return }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
    }
}
