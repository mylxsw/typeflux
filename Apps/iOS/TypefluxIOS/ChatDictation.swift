import AVFoundation
import Observation
import Speech

/// Composer dictation with Apple Speech. `transcript` updates while the user talks;
/// tapping the button again, sending or leaving the conversation stops it.
@MainActor @Observable
final class ChatDictation {
    enum State: Equatable {
        case idle, starting, listening
    }

    private(set) var state: State = .idle
    /// The words recognized so far in the current session.
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private var session: DictationSession?
    private var generation = 0

    func start(locale: Locale = .current) async {
        guard state == .idle else { return }
        generation += 1
        let current = generation
        state = .starting
        transcript = ""
        errorMessage = nil
        guard await DictationSession.authorize() else {
            finish(current, error: "Allow microphone and speech recognition for Typeflux in Settings to dictate.")
            return
        }
        guard current == generation else { return }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            finish(current, error: "Dictation is not available right now.")
            return
        }
        do {
            session = try DictationSession.start(recognizer: recognizer) { [weak self] text, done in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    if let text {
                        self.transcript = text
                    }
                    if done {
                        self.finish(current, error: nil)
                    }
                }
            }
            state = .listening
        } catch {
            finish(current, error: "Dictation is not available right now.")
        }
    }

    func stop() {
        guard state != .idle else { return }
        finish(generation, error: nil)
    }

    private func finish(_ expected: Int, error: String?) {
        guard expected == generation else { return }
        generation += 1
        session?.stop()
        session = nil
        state = .idle
        errorMessage = error
    }
}

/// Owns the audio engine and recognition task. Its callbacks run on audio and
/// Speech queues, so nothing here is isolated to the main actor.
private nonisolated final class DictationSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    static func start(recognizer: SFSpeechRecognizer,
                      onResult: @escaping @Sendable (String?, Bool) -> Void) throws -> DictationSession {
        let session = DictationSession()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        session.request.shouldReportPartialResults = true
        let input = session.engine.inputNode
        // The tap runs on the audio thread; the request is only appended to there.
        nonisolated(unsafe) let request = session.request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        session.engine.prepare()
        try session.engine.start()
        session.task = recognizer.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true)
        }
        return session
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
