import Foundation

final class WorkflowController {
    private static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes

    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let hotkeyService: HotkeyService
    private let audioRecorder: AudioRecorder
    private let sttRouter: STTRouter
    private let llmService: LLMService
    private let textInjector: TextInjector
    private let clipboard: ClipboardService
    private let historyStore: HistoryStore
    private let overlayController: OverlayController

    private var currentSelectedText: String?
    private var isRecording = false
    private var recordingTimeoutTask: Task<Void, Never>?
    private var selectionTask: Task<String?, Never>?

    init(
        appState: AppStateStore,
        settingsStore: SettingsStore,
        hotkeyService: HotkeyService,
        audioRecorder: AudioRecorder,
        sttRouter: STTRouter,
        llmService: LLMService,
        textInjector: TextInjector,
        clipboard: ClipboardService,
        historyStore: HistoryStore,
        overlayController: OverlayController
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.audioRecorder = audioRecorder
        self.sttRouter = sttRouter
        self.llmService = llmService
        self.textInjector = textInjector
        self.clipboard = clipboard
        self.historyStore = historyStore
        self.overlayController = overlayController
    }

    func start() {
        hotkeyService.onPressBegan = { [weak self] in
            self?.handlePressBegan()
        }
        hotkeyService.onPressEnded = { [weak self] in
            self?.handlePressEnded()
        }
        hotkeyService.onError = { [weak self] message in
            guard let self else { return }
            ErrorLogStore.shared.log(message)
            Task { @MainActor in
                self.appState.setStatus(.failed(message: message))
                self.overlayController.showFailure(message: message)
                self.overlayController.dismiss(after: 3.0)
            }
        }

        hotkeyService.start()
    }

    func stop() {
        hotkeyService.stop()
        cancelRecording()
    }
    
    /// Force cancel any ongoing recording
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        _ = try? audioRecorder.stop()
        Task { @MainActor in
            appState.setStatus(.idle)
            overlayController.dismiss(after: 0.3)
        }
        NSLog("[Workflow] Recording cancelled")
    }

    private func handlePressBegan() {
        // Prevent double-start
        guard !isRecording else {
            NSLog("[Workflow] Already recording, ignoring press")
            return
        }
        
        if !PrivacyGuard.isRunningInAppBundle {
            Task { @MainActor in
                let msg = "Please run via scripts/run_dev_app.sh (app bundle required for privacy permissions)"
                appState.setStatus(.failed(message: "Run as .app"))
                overlayController.showFailure(message: msg)
                overlayController.dismiss(after: 3.0)
                ErrorLogStore.shared.log(msg)
            }
            return
        }

        isRecording = true
        NSLog("[Workflow] Recording started")
        
        Task { @MainActor in
            appState.setStatus(.recording)
            overlayController.show()
        }

        selectionTask = Task { [weak self] in
            guard let self else { return nil }
            let text = await self.textInjector.getSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (text?.isEmpty == true) ? nil : text
            if let result {
                NSLog("[Workflow] Selected text: \(result)")
            } else {
                NSLog("[Workflow] No selected text")
            }
            return result
        }

        do {
            try audioRecorder.start(levelHandler: { [weak self] level in
                self?.overlayController.updateLevel(level)
            })
            
            // Set a timeout to auto-stop recording after 10 minutes
            recordingTimeoutTask?.cancel()
            recordingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.recordingTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                NSLog("[Workflow] Recording timeout - auto stopping")
                self?.handlePressEnded()
            }
        } catch {
            isRecording = false
            Task { @MainActor in
                let msg = "Audio start failed: \(error.localizedDescription)"
                appState.setStatus(.failed(message: "Audio start failed"))
                overlayController.showFailure(message: msg)
                overlayController.dismiss(after: 3.0)
                ErrorLogStore.shared.log(msg)
            }
        }
    }

    private func handlePressEnded() {
        // Prevent double-end or end without start
        guard isRecording else {
            NSLog("[Workflow] Not recording, ignoring release")
            return
        }
        
        isRecording = false
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        NSLog("[Workflow] Recording stopped")
        
        Task { @MainActor in
            appState.setStatus(.processing)
            overlayController.showProcessing()
        }

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                let audioFile = try self.audioRecorder.stop()
                let transcribedText = try await self.sttRouter.transcribe(audioFile: audioFile)

                let selectedText = await self.selectionTask?.value
                self.currentSelectedText = selectedText
                let activePersona = self.settingsStore.activePersona

                if let selected = self.currentSelectedText, !selected.isEmpty {
                    let finalText = try await self.generateRewrite(
                        request: LLMRewriteRequest(
                            mode: .editSelection,
                            sourceText: selected,
                            spokenInstruction: transcribedText,
                            personaPrompt: activePersona?.prompt
                        )
                    )
                    self.applyText(finalText, replace: true)
                    self.historyStore.append(record: .init(date: Date(), text: finalText, audioFilePath: audioFile.fileURL.path))
                } else if let activePersona {
                    let finalText = try await self.generateRewrite(
                        request: LLMRewriteRequest(
                            mode: .rewriteTranscript,
                            sourceText: transcribedText,
                            spokenInstruction: nil,
                            personaPrompt: activePersona.prompt
                        )
                    )
                    self.applyText(finalText, replace: false)
                    self.historyStore.append(record: .init(date: Date(), text: finalText, audioFilePath: audioFile.fileURL.path))
                } else {
                    self.applyText(transcribedText, replace: false)
                    self.historyStore.append(record: .init(date: Date(), text: transcribedText, audioFilePath: audioFile.fileURL.path))
                }

                self.historyStore.purge(olderThanDays: 7)

                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.dismissSoon()
                }
            } catch {
                let msg = "Processing failed: \(error.localizedDescription)"
                ErrorLogStore.shared.log(msg)
                await MainActor.run {
                    self.appState.setStatus(.failed(message: "Processing failed"))
                    self.overlayController.showFailure(message: msg)
                    self.overlayController.dismiss(after: 3.0)
                }
            }
        }
    }

    private func generateRewrite(request: LLMRewriteRequest) async throws -> String {
        var buffer = ""
        var lastChunkAt = Date()

        let stream = llmService.streamRewrite(request: request)
        for try await chunk in stream {
            buffer += chunk
            let now = Date()
            if now.timeIntervalSince(lastChunkAt) > 0.15 {
                lastChunkAt = now
                let snapshot = buffer
                await MainActor.run {
                    overlayController.updateStreamingText(snapshot)
                }
            }
        }

        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyText(_ text: String, replace: Bool) {
        clipboard.write(text: text)

        do {
            if replace {
                try textInjector.replaceSelection(text: text)
            } else {
                try textInjector.insert(text: text)
            }
        } catch {
            // Text is already in clipboard, just show a brief info (not an error)
            Task { @MainActor in
                overlayController.updateStreamingText("已复制到剪贴板 (⌘V 粘贴)")
                overlayController.dismiss(after: 2.0)
            }
        }
    }
}
