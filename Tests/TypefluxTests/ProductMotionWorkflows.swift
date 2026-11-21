import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux

extension ProductMotionTests {
    func workflows(_ capture: ProductMotionCapture, directory: URL, selected: Set<String>) async throws {
        for name in ["launcher", "files", "calculator", "top", "sys", "cal", "tz"] where selected.isEmpty || selected.contains(name) {
            capture.clear()
            let suite = "motion-workflow-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let f = try AskTestFixture(modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults)
            defer { f.model.resetSession(); try? FileManager.default.removeItem(at: f.root) }
            let apps = [("Calculator", "计算器"), ("Calendar", "日历"), ("Notes", "备忘录"), ("Reminders", "提醒事项"), ("Preview", "预览"), ("Mail", "邮件"), ("Maps", "地图"), ("Music", "音乐"), ("Photos", "照片"), ("TextEdit", "文本编辑"), ("Books", "图书"), ("FaceTime", "FaceTime")].map { file, title in
                AskAppEntry(name: title, url: URL(fileURLWithPath: "/System/Applications/\(file).app"), bundleID: "com.apple." + file.lowercased(), names: [file])
            }
            f.model.appIndex = AskTestAppIndex(apps)
            f.model.owner = f.sessionState.owner
            f.model.setLauncherImagesVisible(true, prepareIcons: false)
            for app in apps { _ = f.model.launcherIconCache.immediate(.init(kind: .file, value: app.url.path)) }
            f.model.fileIndex = AskTestFileIndex([
                ("/Users/demo/Documents/Typeflux/发布计划.md", .file, 0),
                ("/Users/demo/Documents/Typeflux/发布素材", .folder, 1),
                ("/Users/demo/Documents/Typeflux/发布视频.mp4", .file, 2)
            ])
            if name == "top" {
                f.model.systemMonitorWindow = SystemMonitorWindowController(defaults: defaults, store: SystemMonitorVisualTests.store())
            }
            if name == "sys" {
                let store = SystemInfoStore(reader: FakeSystemInfoReader(SystemInfoFixtures.laptop()), now: { SystemInfoFixtures.now })
                store.refresh(); await store.settle(); f.model.systemInfoStore = store
            }
            if name == "cal" {
                f.model.calendarLauncher = CalendarLauncherModel(provider: FakeCalendarEventProvider(access: .allowed, events: CalendarFixtures.events), dates: CalendarFixtures.dates, now: { CalendarFixtures.date().addingTimeInterval(10*3600) })
            }
            if name == "tz" {
                f.model.worldClock = WorldClockLauncherModel(directory: WorldClockFixtures.directory, clock: { WorldClockFixtures.now }, localZone: { WorldClockFixtures.shanghai })
            }
            capture.mount(AskLauncherView(model: f.model, onDismiss: {}), size: CGSize(width: AskMetrics.launcherWidth, height: 620))
            let duration = name == "launcher" ? 5.5 : 4.0
            var entered = false, changed = false
            try await capture.record(name, duration: duration, directory: directory) { t in
                switch name {
                case "launcher":
                    if t > 1 { f.model.launcherDraft.text = String("jsq".prefix(min(3,Int((t-1)*3)))) }
                case "files":
                    f.model.launcherDraft.text = String("发布".prefix(min(2,max(0,Int((t-0.3)*4)))))
                case "calculator":
                    let input = "(128+256)*0.85"
                    f.model.launcherDraft.text = String(input.prefix(min(input.count,max(0,Int((t-0.2)*9)))))
                default:
                    if t < 0.8 { f.model.launcherDraft.text = String(name.prefix(min(name.count,max(0,Int((t-0.1)*7))))) }
                    if t > 0.8 && !entered {
                        entered = true
                        if name == "top" { f.model.openSystemMonitorInLauncher(focus: nil) }
                        else {
                            let id = name == "sys" ? AskSystemInfoPlugin.id : name == "cal" ? AskCalendarPlugin.id : AskWorldClockPlugin.id
                            #expect(f.model.enterLauncherKeywordFromText(pluginID: id))
                        }
                    }
                    if t > 2 && !changed {
                        changed = true
                        if name == "top" { f.model.systemMonitor.setFocus(.memory) }
                        if name == "sys" { f.model.systemInfo.show(.storage) }
                        if name == "cal" { f.model.calendarLauncher.selectEvent("review") }
                    }
                    if name == "tz", t > 1.7 {
                        let input = "09:00 London to Tokyo"
                        f.model.launcherDraft.text = String(input.prefix(min(input.count,Int((t-1.7)*22))))
                    }
                }
            }
            f.model.setLauncherImagesVisible(false)
            if name == "cal" { f.model.calendarLauncher.close() }
        }
    }

    func recording(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let f = ScreenRecordingCoordinatorTests.Fixture()
        await f.setup()
        defer { Task { @MainActor in await f.clean() } }
        f.model.options.countdown = 0
        f.model.options.systemAudio = true
        let source = directory.appendingPathComponent("voice.mov")
        f.engine.movie = { url in try FileManager.default.copyItem(at: source, to: url) }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 240, height: 160)
        var thumbnails: [CGImage] = []
        for index in 0..<16 { thumbnails.append(try generator.copyCGImage(at: CMTime(seconds: Double(index)*0.45, preferredTimescale: 600), actualTime: nil)) }
        let movieSize = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let movieBytes = (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let media = ScreenRecordingPreviewMedia(thumbnails: thumbnails, size: movieSize, fps: 30, fileBytes: movieBytes, audio: .absent)
        f.model.loadTimeline = { _ in media }
        let state = ProductMotionState(); state.text = "发布清单\n\n✓ 完成产品视频\n✓ 准备发布文案\n✓ 收集用户反馈"
        capture.mount(ProductMotionDocument(state: state), size: CGSize(width: 790, height: 430), origin: CGPoint(x: 165, y: 200))
        capture.mount(ScreenRecordingToolbar(model: f.model, levelProvider: { 0.6 }, close: {}, chooseDirectory: {}), size: CGSize(width: 900, height: 100), origin: CGPoint(x: 110, y: 65))
        var phase = 0
        try await capture.record("recording", duration: 8, directory: directory) { t in
            f.engine.seconds = max(0,t-0.6)
            if t > 0.6 && phase == 0 {
                phase = 1; f.model.start(); await f.model.pendingTask?.value
                capture.clear()
                capture.mount(ProductMotionDocument(state: state), size: CGSize(width: 790, height: 430), origin: CGPoint(x: 165, y: 200))
                capture.mount(ScreenRecordingCapsule(model: f.model, levelProvider: { 0.5 }, close: {}), size: CGSize(width: 500, height: 100), origin: CGPoint(x: 310, y: 80))
            }
            if t > 1.1 && t < 2.4 { state.text = "发布清单\n\n✓ 完成产品视频\n✓ 准备发布文案\n✓ 收集用户反馈\n\n" + String("准备好了，就分享出去。".prefix(Int((t-1.1)*12))) }
            if t > 2.5 && phase == 1 {
                phase = 2; f.model.stop(); await f.model.pendingTask?.value
                for _ in 0..<60 where f.model.media.thumbnails.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                capture.clear()
                capture.mount(ScreenRecordingPreviewView(model: f.model).environment(\.interfaceStyle, .classic), size: CGSize(width: 1000, height: 660))
            }
            if t > 3.5 && t < 5.5 { f.model.setTrimStart(min(1.2,(t-3.5)*0.6)); f.model.setTrimEnd(max(6.4,8-(t-3.5)*0.8)) }
            if t > 6.1 { f.model.options.format = .gif }
        }
        #expect(f.model.trimStart > 0)
    }
}
