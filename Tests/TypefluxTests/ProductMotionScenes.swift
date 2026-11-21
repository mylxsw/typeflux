import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
final class ProductMotionState: ObservableObject {
    @Published var text = ""
    @Published var caption = ""
    @Published var showsCapsule = false
    @Published var voice = VoiceCapsuleSnapshot(phase: .listening(handsFree: false), expanded: true)
}

/// A synthetic writing surface used to show input and paste results without reading personal apps.
struct ProductMotionDocument: View {
    @ObservedObject var state: ProductMotionState
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { $0.opacity(0.8).frame(width: 9, height: 9).clipShape(Circle()) }
                Spacer(); Text("发布计划 · 示例文档").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
            }
            Text("让想法，开始发生。").font(.system(size: 30, weight: .semibold))
            TextEditor(text: $state.text).font(.system(size: 21)).scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack { Text("Typeflux").font(.system(size: 12, weight: .semibold)); Spacer(); Text("少一点切换，多一点心流。").font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(30).background(Color(red: 0.10, green: 0.11, blue: 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1), lineWidth: 1))
    }
}

struct ProductVoiceMotion: View {
    @ObservedObject var state: ProductMotionState
    var body: some View {
        ZStack {
            ProductMotionDocument(state: state).frame(width: 790, height: 430).offset(y: 35)
            if state.showsCapsule {
                CornerCardCapsule(snapshot: state.voice, actions: .init()).offset(x: 295, y: -215)
            }
        }.frame(width: 1120, height: 740)
    }
}

extension ProductMotionTests {
    func voice(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let state = ProductMotionState()
        capture.mount(ProductVoiceMotion(state: state), size: capture.size)
        let sentence = "周五发布 Typeflux，准备产品视频，整理使用反馈。"
        var inserted = false
        try await capture.record("voice", duration: 8, directory: directory) { t in
            state.showsCapsule = t > 0.25 && t < 5.5
            state.voice.level = Float(0.25 + 0.6 * abs(sin(t * 8)))
            state.voice.targetAppName = "示例文档"
            if t < 4.2 {
                state.voice.text = String(sentence.prefix(max(0, Int((t-0.4)/3.6 * Double(sentence.count)))))
            } else {
                state.voice.phase = .processing
                state.voice.progress = min(1, (t-4.2)/0.8)
            }
            if t > 5.05 && !inserted {
                inserted = true
                state.text = "周五发布 Typeflux。\n\n• 准备产品视频\n• 整理使用反馈"
            }
        }
    }

    func chat(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let suite = "motion-chat-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let f = try AskTestFixture(modelLibrary: library, defaults: defaults)
        defer { f.model.resetSession(); try? FileManager.default.removeItem(at: f.root) }
        var c = AskConversation(id: "motion-chat", title: "把想法变成发布计划", revision: 1, updatedAt: Date(), messages: [])
        c.kind = "chat"
        await f.api.seed(c); await f.model.refreshHistory(); await f.model.select(c.id)
        defaults.set(true, forKey: "ask.sidebarCollapsed")
        capture.mount(AskConversationView(model: f.model).defaultAppStorage(defaults)
            .clipShape(RoundedRectangle(cornerRadius: 18)), size: CGSize(width: 1024, height: 640))
        let question = "把这周的想法，整理成一份产品发布计划。"
        let answer = "## 从想法，到上线\n\n**周一 · 确定重点**\n选出三个最值得展示的功能，写清用户能得到什么。\n\n**周三 · 做出作品**\n录制真实操作，把输入、过程和结果连起来。\n\n**周五 · 发布与交流**\n分享产品视频，收集第一批用户反馈。\n\n让计划开始发生。"
        var submitted = false, count = -1
        try await capture.record("chat", duration: 10, directory: directory) { t in
            if t < 2 {
                f.model.draft.text = String(question.prefix(max(0, Int((t-0.3)/1.5 * Double(question.count)))))
            } else {
                if !submitted {
                    submitted = true; f.model.draft.text = ""
                    c.messages = [.init(id: "q", role: "user", text: question, createdAt: Date())]
                }
                let n = min(answer.count, max(0, Int((t-2.4)/5.4 * Double(answer.count))))
                if n != count {
                    count = n; c.revision += 1; c.updatedAt = Date()
                    c.messages = [c.messages[0], .init(id: "a", role: "assistant", text: String(answer.prefix(n)), createdAt: Date())]
                    try await f.model.accept(c, route: .init(account: f.sessionState.owner, owner: f.sessionState.owner, token: f.sessionState.token))
                }
            }
        }
        #expect(f.model.selected?.messages.last?.text == answer)
    }

    func clipboard(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let state = ProductMotionState(); state.text = "产品发布素材\n\n"
        let doc = capture.mount(ProductMotionDocument(state: state), size: CGSize(width: 790, height: 430))
        doc.alphaValue = 0.35
        let model = ClipboardPanelModel()
        let entries = [
            ClipboardTestSupport.entry(.text, text: "Typeflux：少一点切换，多一点心流。", sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录"),
            ClipboardTestSupport.entry(.link, text: "https://typeflux.app", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, text: "发布计划：准备视频，收集使用反馈。", sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录"),
            ClipboardTestSupport.entry(.text, text: "灵感，是行动的开始。", sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录")
        ]
        model.reset(entries: entries); model.showsPreview = true
        let panel = capture.mount(ClipboardPanelView(model: model, focusRequest: 0), size: CGSize(width: ClipboardPanelView.size(showsPreview: true).width, height: ClipboardPanelView.height))
        panel.isHidden = true
        model.onAction = { _, entry in state.text += entry.text ?? ""; panel.isHidden = true; doc.alphaValue = 1 }
        var pasted = false
        try await capture.record("clipboard", duration: 7, directory: directory) { t in
            if t > 0.4 && !pasted { panel.isHidden = false }
            if t > 1.1 && t < 1.8 { model.select(index: 1) }
            if t > 2 && t < 4 { model.query = String("发布".prefix(min(2, Int((t-2)*3)))) }
            if t > 4.5 && !pasted { pasted = true; model.perform(.paste) }
        }
        #expect(pasted && state.text.contains("发布计划"))
    }

    func screenshot(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let state = ProductMotionState(); state.text = "发布清单\n\n✓ 语音输入：说完就写好\n✓ Chat：把想法展开成计划\n✓ 环：常用动作，随手调用\n\n准备好了，就分享出去。"
        let host = capture.mount(ProductMotionDocument(state: state), size: CGSize(width: 960, height: 600))
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 600), scale: 2, image: try #require(bitmap.cgImage))
        capture.clear()
        let defaults = try #require(UserDefaults(suiteName: "motion-screenshot-" + UUID().uuidString))
        let overlay = ScreenshotOverlayView(display: display, windows: [], toolStyles: ScreenshotToolStyleStore(defaults: defaults))
        overlay.frame.origin = CGPoint(x: 80, y: 70)
        capture.stage.addSubview(overlay)
        var phase = 0
        try await capture.record("screenshot", duration: 7, directory: directory) { t in
            if t > 0.4 && phase == 0 { phase = 1; overlay.mouseDown(at: CGPoint(x: 20, y: 20), clickCount: 1) }
            if phase == 1 { overlay.mouseDragged(to: CGPoint(x: 20 + min(1,(t-0.4)/0.9)*910, y: 20 + min(1,(t-0.4)/0.9)*475)) }
            if t > 1.35 && phase == 1 { phase = 2; overlay.mouseUp(at: CGPoint(x: 930, y: 495)); overlay.perform(.tool(.rect)); overlay.perform(.color(.blue)); overlay.perform(.size(3)) }
            if t > 2 && phase == 2 { phase = 3; overlay.mouseDown(at: CGPoint(x: 45, y: 200), clickCount: 1) }
            if phase == 3 { overlay.mouseDragged(to: CGPoint(x: 45 + min(1,(t-2)/0.85)*610, y: 200 + min(1,(t-2)/0.85)*155)) }
            if t > 2.9 && phase == 3 { phase = 4; overlay.mouseUp(at: CGPoint(x: 655, y: 355)); overlay.perform(.tool(.arrow)) }
            if t > 3.6 && phase == 4 { phase = 5; overlay.mouseDown(at: CGPoint(x: 795, y: 390), clickCount: 1) }
            if phase == 5 { overlay.mouseDragged(to: CGPoint(x: 795-min(1,(t-3.6)/0.75)*110, y: 390-min(1,(t-3.6)/0.75)*95)) }
            if t > 4.4 && phase == 5 { phase = 6; overlay.mouseUp(at: CGPoint(x: 685, y: 295)) }
            if let toolbar = overlay.toolbar {
                toolbar.rootView = AnyView(ScreenshotEditorToolbar(state: overlay.toolbarModel.state) { overlay.perform($0) }
                    .padding(ScreenshotOverlayView.toolbarShadowInset)
                    .environment(\.colorScheme, .dark).environment(\.interfaceStyle, .classic)
                    .environment(\.askGlassMaterialOverride, .opaque))
            }
        }
        #expect(overlay.editor.visibleAnnotations.count == 2)
    }
}
