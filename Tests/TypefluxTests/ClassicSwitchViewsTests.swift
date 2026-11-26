import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private struct ViewsFixedFetcher: ClassicReleaseFetching {
    var package: ClassicPackage? = ClassicPackage(
        version: "0.5.0", downloadURL: URL(string: "https://example.com/classic.zip")!, sha256: nil, fileSize: nil
    )
    func latestClassicPackage() async throws -> ClassicPackage? { package }
}

private struct ViewsDownloader: ClassicPackageDownloading {
    var hang = false
    func download(from _: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        progress(0.4)
        if hang { try await Task.sleep(for: .seconds(60)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-views-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: url)
        return url
    }
}

private struct ViewsRejectingInstaller: ClassicSwitchInstalling {
    func stage(archiveURL: URL, package _: ClassicPackage) async throws -> ClassicStagedApp {
        try? FileManager.default.removeItem(at: archiveURL)
        throw ClassicBundleVerificationError.teamIdentifierMismatch
    }
    func launchReplacement(_: ClassicStagedApp) throws {}
    func discard(_: ClassicStagedApp) {}
}

/// Renders the introduction, every switch phase and the entry wrappers, and drives the panels.
@Suite("Classic switch views", .serialized, .exclusiveUIState)
@MainActor
struct ClassicSwitchViewsTests {
    private func makeController(hang: Bool = false, package: ClassicPackage?? = nil) -> ClassicSwitchController {
        var fetcher = ViewsFixedFetcher()
        if let package { fetcher.package = package }
        return ClassicSwitchController(fetcher: fetcher, downloader: ViewsDownloader(hang: hang),
                                       installer: ViewsRejectingInstaller(), terminate: {})
    }

    private func fittingSize(_ view: some View, dark: Bool = false) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test func introRendersWithAndWithoutSwitchAction() {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for dark in [false, true] {
                let full = fittingSize(ClassicIntroView(canSwitch: true, onContinue: {}, onSwitch: {}, onLearnMore: {}), dark: dark)
                let reduced = fittingSize(ClassicIntroView(canSwitch: false, onContinue: {}, onSwitch: {}, onLearnMore: {}), dark: dark)
                #expect(full.width == 560)
                #expect(full.height > 300)
                #expect(reduced.height == full.height)
            }
        }
        #expect(ClassicFeatureComparison.missingInClassic.count == 5)
        #expect(ClassicFeatureComparison.missingInClassic.allSatisfy { !$0.title.isEmpty && $0.title != "classic.feature.\($0.id)" })
    }

    @Test func everySwitchPhaseRenders() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        AppLocalization.shared.setLanguage(.english)
        let confirming = makeController()
        confirming.beginSwitch()
        let confirmSize = fittingSize(ClassicSwitchView(controller: confirming))
        #expect(confirmSize.width == 480)

        let downloading = makeController(hang: true)
        downloading.beginSwitch()
        downloading.confirm()
        for _ in 0 ..< 100 where downloading.phase != .downloading(0.4) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloading.phase == .downloading(0.4))
        let downloadSize = fittingSize(ClassicSwitchView(controller: downloading))
        #expect(downloadSize.height < confirmSize.height)
        downloading.cancel()

        let indeterminate = makeController(hang: true)
        indeterminate.beginSwitch()
        indeterminate.confirm()
        #expect(fittingSize(ClassicSwitchView(controller: indeterminate)).height > 0)
        indeterminate.cancel()

        let failed = makeController()
        failed.beginSwitch()
        failed.confirm()
        await failed.waitForSwitch()
        guard case .failed = failed.phase else {
            Issue.record("expected failure, got \(failed.phase)")
            return
        }
        #expect(fittingSize(ClassicSwitchView(controller: failed)).height > 0)
    }

    @Test func entryWrapperFollowsAvailability() async {
        let available = makeController()
        let unavailable = makeController(package: .some(nil))
        _ = await available.refreshAvailability()
        _ = await unavailable.refreshAvailability()
        let probe = { (controller: ClassicSwitchController) in
            VStack(spacing: 0) {
                ClassicSwitchEntry(controller: controller) { Color.red.frame(width: 20, height: 20) }
            }
            .refreshesClassicAvailability(controller)
        }
        #expect(fittingSize(probe(available)).height == 20)
        #expect(fittingSize(probe(unavailable)).height == 0)
    }

    @Test func switchWindowOpensAndClosesWithTheFlow() async throws {
        let controller = makeController()
        let windows = ClassicSwitchWindowController(controller: controller)
        windows.appearanceMode = { .dark }
        windows.present()
        #expect(controller.phase == .confirming)
        #expect(windows.isPresented)
        #expect(windows.window?.appearance?.name == .darkAqua)

        // Presenting again keeps the same window.
        let first = windows.window
        windows.present()
        #expect(windows.window === first)

        controller.cancel()
        for _ in 0 ..< 100 where windows.window != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(windows.window == nil)
        #expect(controller.phase == .idle)
    }

    @Test func closingTheSwitchWindowCancelsTheFlow() async throws {
        let controller = makeController(hang: true)
        let windows = ClassicSwitchWindowController(controller: controller)
        windows.present()
        controller.confirm()
        #expect(windows.windowShouldClose(try #require(windows.window)))
        windows.window?.close()
        #expect(controller.phase == .idle)
    }

    @Test func introWindowShowsAndCloses() throws {
        var switched = 0
        let intro = ClassicIntroWindowController(appearanceMode: .light, canSwitch: true) { switched += 1 }
        intro.show()
        let window = try #require(intro.window)
        #expect(window.isVisible)
        #expect(window.appearance?.name == .aqua)
        window.close()
        #expect(!window.isVisible)
        #expect(switched == 0)
    }
}
