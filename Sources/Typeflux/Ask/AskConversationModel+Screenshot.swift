import CoreGraphics
import Foundation

/// A screenshot handed to the launcher: the image, for a question about it, and its text,
/// read on this Mac from the moment it arrives.
struct AskLauncherScreenshot {
    let image: ScreenshotFollowUpImage
    let source: AskScreenshotTextSource
}

/// What happens after a screenshot in the launcher: its text in a result card (`ocr`), that
/// text translated (`fy`), or the image attached to a new question (`jtai`). The screenshot
/// module calls this through `ScreenshotFollowUpHandling`, so it never depends on `Ask/`.
extension AskConversationModel: ScreenshotFollowUpHandling {
    func handle(_ followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage) {
        switch followUp {
        case .recognizeText, .translate:
            let screenshot = makeLauncherScreenshot(image)
            launcherScreenshot = screenshot
            showLauncherThen { [weak self] in
                guard let self, launcherScreenshot?.source.id == screenshot.source.id else { return }
                showScreenshotText()
                if followUp == .translate { translateWhenRead(screenshot) }
            }
        case .askAI:
            releaseLauncherScreenshot()
            // The screenshot is the image; the launcher need not capture the screen as it opens.
            launcherDraft.includeScreenshot = false
            showLauncherThen { [weak self] in self?.attachScreenshotToLauncher(image) }
        }
    }

    /// Starts reading the text at once, off the main thread.
    func makeLauncherScreenshot(_ image: ScreenshotFollowUpImage) -> AskLauncherScreenshot {
        let recognizer = screenshotTextRecognizer
        let picture = image.image
        let recognition = Task.detached(priority: .userInitiated) {
            try await recognizer.recognizeText(in: .image(picture))
        }
        let fits = (try? ImageTiling.slices(imageSize: image.pixelSize,
                                            longEdge: AskAttachmentLimits.imageLongEdge).get()) != nil
        return AskLauncherScreenshot(image: image, source: AskScreenshotTextSource(
            pixelSize: image.pixelSize, fitsQuestion: fits, recognition: recognition
        ))
    }

    /// The launcher opens first and captures its context (the app, the selection); then `then` runs.
    private func showLauncherThen(_ then: @escaping @MainActor () -> Void) {
        guard let onShowLauncher else { then(); return }
        onShowLauncher(then)
    }

    /// Enters the text keyword with nothing typed, so its card shows the screenshot's text.
    func showScreenshotText() {
        guard let keyword = plugins.availableKeywords.first(where: {
            $0.enabled && $0.pluginID == AskScreenshotTextPlugin.id
        }) ?? AskScreenshotTextPlugin.keywords.first else { return }
        launcherDraft.text = ""
        plugins.enter(keyword)
        plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language,
                       runWhenPlanned: true)
    }

    /// Translates the text once it is read; nothing happens when none was found (the card says
    /// so) or the user moved on meanwhile.
    private func translateWhenRead(_ screenshot: AskLauncherScreenshot) {
        Task { [weak self] in
            guard let text = try? await screenshot.source.recognition.value.string, let self,
                  launcherScreenshot?.source.id == screenshot.source.id,
                  plugins.keyword?.pluginID == AskScreenshotTextPlugin.id else { return }
            translateInLauncher(text)
        }
    }

    /// Runs the translation keyword (`fy`, or another one the user gave translation) on `text`.
    /// - Returns: false, saying so, when translation has no keyword.
    @discardableResult
    func translateInLauncher(_ text: String) -> Bool {
        let keywords = plugins.availableKeywords.filter {
            $0.enabled && $0.pluginID == AskTranslatePlugin.id && !AskTranslatePlugin.opensWordBook($0.options)
        }
        guard let keyword = keywords.first(where: { $0.contains("fy") }) ?? keywords.first,
              runLauncherKeyword(keyword.keyword, argument: text, chain: []) else {
            confirm(L("screenshot.translate.unavailable"))
            return false
        }
        return true
    }

    /// An action on the screenshot waiting in the launcher (the text card's ⌘↩).
    func performScreenshotFollowUp(_ followUp: ScreenshotFollowUp) -> PluginActionOutcome {
        guard let screenshot = launcherScreenshot else { return .stay }
        switch followUp {
        case .askAI:
            attachScreenshotToLauncher(screenshot.image)
        case .recognizeText:
            showScreenshotText()
        case .translate:
            translateWhenRead(screenshot)
        }
        return .stay
    }

    /// A new question about the screenshot: the launcher leaves keyword mode and takes the image
    /// (in pieces when long) as attachments, instead of its own full-screen screenshot.
    func attachScreenshotToLauncher(_ image: ScreenshotFollowUpImage) {
        plugins.deactivate()
        launcherDraft.text = ""
        launcherDraft.includeScreenshot = false
        launcherDraft.screenshot = nil
        let key = visionDraftKey(launcher: true)
        attachmentLoads[key, default: 0] += 1
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { AskScreenshotAttachments.make(image) }.value
            guard let self else { return }
            let remaining = (attachmentLoads[key] ?? 1) - 1
            attachmentLoads[key] = remaining > 0 ? remaining : nil
            applyScreenshotAttachments(result, image: image)
        }
    }

    func applyScreenshotAttachments(_ result: Result<[AskAttachment], AskScreenshotAttachments.Failure>,
                                    image: ScreenshotFollowUpImage) {
        switch result {
        case let .success(items):
            launcherDraft.includeScreenshot = false
            applyAttachments(AskAttachmentBatch(items: items), launcher: true)
        case .failure(.tooLong):
            // Too many pieces for one question: read its text first, and ask about that.
            launcherScreenshot = makeLauncherScreenshot(image)
            showScreenshotText()
            confirm(L("screenshot.ask.tooLong"), for: .seconds(6))
        case .failure(.unreadable):
            launcherAttachmentNotice = AskAttachmentError.unreadable(L("screenshot.ask.attachmentName")).message
        }
    }

    /// The launcher closed or moved on: the screenshot and its text go.
    func releaseLauncherScreenshot() {
        launcherScreenshot?.source.recognition.cancel()
        launcherScreenshot = nil
    }
}
