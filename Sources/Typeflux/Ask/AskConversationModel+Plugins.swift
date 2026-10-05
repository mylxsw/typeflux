import AVFoundation
import Foundation

/// The plugins the launcher knows and the keywords they start with.
enum AskPluginRegistry {
    static var defaultKeywords: [AskKeyword] { AskTranslatePlugin.keywords }
}

extension AskConversationModel {
    /// The user's keywords, or each plugin's defaults until they change them.
    var launcherKeywords: [AskKeyword] {
        modelLibrary.settings.askLauncherKeywords ?? AskPluginRegistry.defaultKeywords
    }

    func makeLauncherPlugins() -> [any AskLauncherPlugin] {
        let settings = modelLibrary.settings
        return [AskTranslatePlugin(
            onDevice: AskOnDeviceTranslationEngine(),
            ai: translationAI,
            aiName: { [weak settings] in settings.map { $0.llmModel.isEmpty ? "AI" : $0.llmModel } ?? "AI" },
            secondLanguage: { [weak settings] language in
                settings?.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
            }
        )]
    }

    /// What a plugin result's action needs from the launcher afterwards.
    enum PluginActionOutcome: Equatable {
        /// The launcher closes: copied, written back, or sent to the AI.
        case close
        case stay
    }

    /// Carries out a result's action.
    func performPluginAction(_ action: AskPluginAction) -> PluginActionOutcome {
        switch action.kind {
        case let .copy(text):
            AskQuickResults.copy(text)
            finishPluginResult()
            return .close
        case let .writeBack(text):
            finishPluginResult()
            writeBack(text)
            return .close
        case let .speak(text, language):
            speak(text, language)
            return .stay
        case let .rerun(options):
            plugins.rerun(with: options, selection: launcherDraft.sentSelection, text: launcherDraft.text,
                          language: AppLocalization.shared.language)
            return .stay
        case .compare:
            plugins.comparing.toggle()
            return .stay
        case let .askAI(prompt):
            askAIFromPlugin(prompt)
            return .close
        }
    }

    /// ⌘↩ in keyword mode: the AI gets the plugin's prompt about its result, or
    /// the typed text (the selection rides along with the draft as always).
    func askAIFromPlugin(_ prompt: String? = nil) {
        let argument = launcherDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt ?? (argument.isEmpty ? plugins.plugin.map { L("ask.plugin.askAI.selection", $0.title) } ?? "" : argument)
        plugins.deactivate()
        launcherDraft.text = text
        submitLauncher()
    }

    /// The result was used: the next launch starts empty, out of keyword mode.
    func finishPluginResult() {
        plugins.deactivate()
        finishQuickResult()
    }

    /// Closing the launcher in keyword mode puts the keyword back in front of
    /// its text, so the saved draft opens in the same mode next time.
    func foldLauncherKeyword() {
        guard plugins.isActive else { return }
        if let text = plugins.deactivate(argument: launcherDraft.text) { launcherDraft.text = text }
    }

    /// Types `text` into the app the launcher came from, over its selection when
    /// it still has one. The launcher has closed by now; if typing fails the
    /// text is on the clipboard and the next launcher says so.
    func writeBack(_ text: String) {
        guard let deliverText else { AskQuickResults.copy(text); return }
        Task { [weak self] in
            // Let the source app take its own window's focus back first.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try await deliverText(text)
            } catch {
                AskQuickResults.copy(text)
                self?.confirm(L("ask.plugin.writeBack.failed"), for: .seconds(8))
            }
        }
    }
}

/// Reads results aloud with the system voice for their language.
@MainActor
final class AskSpeaker {
    static let shared = AskSpeaker()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        synthesizer.speak(utterance)
    }
}
