import Foundation

protocol BundledSenseVoiceLinking: AnyObject {
    @discardableResult
    func ensureBundledSenseVoiceLinked() throws -> Bool
}

extension LocalModelManager: BundledSenseVoiceLinking {}

/// Runs once at app start to activate the bundled SenseVoice copy that ships with
/// the full installer variant.
///
/// Without this, the Application Support copy and the `prepared.json`
/// record are only written lazily on the first transcription call. That lazy
/// path is fragile: `AutoModelDownloadService.triggerIfNeeded()` reads
/// `preparedModelInfo` on startup to expose the local-first fallback route
/// (see `STTRouter.transcribeWithAutoModelIfReady`), and if the bundled copy
/// hasn't been recorded yet, the route is skipped — even for users who logged
/// into Typeflux Cloud and would otherwise hit SenseVoice first.
///
/// Calling `applyIfNeeded()` synchronously at startup makes the bundled model
/// visible to every downstream consumer before the user can press the hotkey.
@MainActor
final class BundledModelAutoSetup {
    private let linker: BundledSenseVoiceLinking

    init(linker: BundledSenseVoiceLinking) {
        self.linker = linker
    }

    func applyIfNeeded() {
        do {
            let hadBundle = try linker.ensureBundledSenseVoiceLinked()
            NSLog("[BundledModelAutoSetup] isFullInstall=\(hadBundle)")
            if hadBundle {
                NSLog("[BundledModelAutoSetup] bundled SenseVoice copied and recorded")
            }
        } catch {
            NSLog("[BundledModelAutoSetup] failed to copy bundled SenseVoice: \(error.localizedDescription)")
        }
    }
}
