import AppKit
import Foundation

/// Routes explicit entry points and safe write-back through DI-owned system services.
@MainActor
final class AskTranslationPanelCoordinator: ScreenshotFollowUpHandling {
    let model: AskTranslationPanelModel
    let controller: AskTranslationPanelController
    private let injector: any TextInjector
    private let recognizer: any ImageTextRecognizing
    private var entryTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var generation = UUID()
    private var selection: TextSelectionSnapshot?
    private var selectedText: String?
    private var processID: pid_t?
    weak var otherScreenshotHandler: (any ScreenshotFollowUpHandling)?
    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var activate: (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) }
    var restoreFocus: () async -> Void = { try? await Task.sleep(for: .milliseconds(150)) }

    init(model: AskTranslationPanelModel, controller: AskTranslationPanelController,
         injector: any TextInjector, recognizer: any ImageTextRecognizing) {
        self.model = model
        self.controller = controller
        self.injector = injector
        self.recognizer = recognizer
        model.onInsert = { [weak self] text in self?.insert(text) }
        let hide = model.onDismiss
        model.onDismiss = { [weak self] in self?.cancelEntry(); hide() }
    }

    deinit { entryTask?.cancel(); selectionTask?.cancel(); deliveryTask?.cancel() }

    func handle(_ followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage) {
        if followUp == .translate {
            openScreenshot(image)
        } else {
            otherScreenshotHandler?.handle(followUp, image: image)
        }
    }

    func openInput() {
        if selectionTask != nil { cancelEntry() }
        if controller.isPresented {
            controller.focus(); return
        }
        cancelEntry()
        processID = frontmost()
        selection = nil
        selectedText = nil
        model.open(source: .input)
        controller.present()
    }

    func toggleSelection() {
        if controller.isPresented {
            model.dismiss()
        } else {
            openSelection()
        }
    }

    func openSelection() {
        selectionTask?.cancel()
        let current = generation
        let wasPresented = controller.isPresented
        if !wasPresented {
            processID = frontmost()
            selection = nil
            selectedText = nil
            model.open(source: .input)
            controller.present(focusEditor: false)
        }
        let initialText = model.text
        selectionTask = Task { [weak self, injector] in
            let snapshot = await injector.selectionSnapshot(for: .explicitSelectionAction)
            guard let self, generation == current, !Task.isCancelled else { return }
            selectionTask = nil
            guard controller.isPresented else { return }
            if !wasPresented, model.text != initialText {
                controller.focus()
                return
            }
            guard snapshot.hasAskSelectionContext, let text = snapshot.selectedText else {
                openInput()
                return
            }
            cancelEntry()
            selection = snapshot
            selectedText = text
            processID = snapshot.processID
            let keepsPosition = controller.isPresented && model.pinned
            model.open(source: .selection, text: text)
            model.pinned = keepsPosition
            if keepsPosition {
                controller.focus()
            } else {
                controller.present(selection: snapshot.selectionBounds)
            }
            model.translate()
        }
    }

    func openScreenshot(_ image: ScreenshotFollowUpImage) {
        cancelEntry()
        let current = generation
        processID = frontmost()
        selection = nil
        selectedText = nil
        let thumbnail = NSImage(cgImage: image.image, size: NSSize(width: image.pixelSize.width / image.scale,
                                                                   height: image.pixelSize.height / image.scale))
        model.open(source: .screenshot, image: thumbnail)
        model.notice = L("ask.translation.panel.recognizing")
        controller.present()
        entryTask = Task { [weak self, recognizer] in
            do {
                let recognized = try await recognizer.recognizeText(in: .image(image.image))
                guard let self, generation == current, !Task.isCancelled, controller.isPresented,
                      model.source == .screenshot, model.screenshot === thumbnail, model.text.isEmpty else { return }
                model.finishRecognition(text: recognized.string ?? "", lines: recognized.lines.count)
                if recognized.string == nil {
                    model.notice = L("ask.translation.panel.noText")
                } else {
                    model.translate()
                }
                entryTask = nil
            } catch {
                guard let self, generation == current, !Task.isCancelled, controller.isPresented else { return }
                model.notice = L("ask.translation.panel.recognitionFailed")
                entryTask = nil
            }
        }
    }

    /// Already computed results move without a second provider call. The launcher may still
    /// be streaming; its host supplies further progress until the run settles.
    func moveFromLauncher(_ result: AskPluginOutput) {
        cancelEntry()
        selection = nil
        selectedText = result.translation?.replacesSelection == true ? result.original : nil
        processID = frontmost()
        model.importLauncher(result)
        controller.present()
    }

    @discardableResult
    func moveFromLauncher(_ session: AskPluginSession, closeLauncher: () -> Void) -> Bool {
        guard session.plugin?.id == AskTranslatePlugin.id, session.isPlanCurrent else { return false }
        let transfer = UUID()
        guard let handoff = session.handOff(to: { [weak model] event in model?.receiveHandoff(event, id: transfer) })
        else {
            // Private live previews also move, without authorizing a provider request.
            guard let result = session.currentOutput, result.translation != nil else { return false }
            closeLauncher()
            moveFromLauncher(result)
            return true
        }
        let initial = handoff.output ?? AskPluginOutput(body: "", original: handoff.request.text, meta: [], source: "",
                                                        actions: [], translation: .init(
                                                            results: [],
                                                            source: handoff.plan.values["source"],
                                                            target: handoff.plan.values["target"] ?? "en",
                                                            interface: handoff.request.interfaceLanguage,
                                                            submitted: handoff.plan.mode == .onSubmit || handoff.plan
                                                                .values["submitted"] == "true",
                                                            isLookup: AskWordCard.isLookup(handoff.request.text),
                                                            replacesSelection: handoff.request.origin == .selection
                                                        ))
        closeLauncher()
        moveFromLauncher(initial)
        model.adoptHandoff(handoff, id: transfer)
        return true
    }

    func waitForEntry() async {
        await selectionTask?.value
        await entryTask?.value
    }

    func waitForDelivery() async {
        await deliveryTask?.value
    }

    private func cancelEntry() {
        selectionTask?.cancel()
        selectionTask = nil
        entryTask?.cancel()
        entryTask = nil
        generation = UUID()
    }

    func insert(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, deliveryTask == nil else { return }
        let expectedProcess = processID
        let captured = selection
        let selectedText = selectedText
        let pinned = model.pinned
        if pinned {
            controller.presentedWindow?.resignKey()
        } else {
            model.dismiss()
        }
        deliveryTask = Task { [weak self, injector] in
            guard let self else { return }
            defer { deliveryTask = nil }
            do {
                guard let expectedProcess else { throw TextDeliveryError.noInput }
                activate(expectedProcess)
                await restoreFocus()
                guard !Task.isCancelled, frontmost() == expectedProcess else { throw TextDeliveryError.targetChanged }
                let destination = try await deliveryDestination(
                    processID: expectedProcess,
                    captured: captured,
                    selectedText: selectedText
                )
                let result = try await injector.deliver(text: text, to: destination)
                guard case .delivered = result else { throw TextDeliveryError.noInput }
            } catch {
                guard !Task.isCancelled else { return }
                model.onCopy(text)
                model.notice = L("ask.translation.panel.insertionFailed")
                if !controller.isPresented {
                    controller.present()
                }
            }
        }
    }

    private func deliveryDestination(processID: pid_t, captured: TextSelectionSnapshot?,
                                     selectedText: String?) async throws -> TextDeliveryDestination {
        guard let selectedText else { return .currentInput }
        let target: TextSelectionSnapshot = if let captured {
            captured
        } else {
            await injector.selectionSnapshot(for: .explicitSelectionAction)
        }
        guard target.processID == processID, target.canReplaceSelection, target.selectedText == selectedText else {
            throw TextDeliveryError.selectionChanged
        }
        return .selection(target)
    }
}
