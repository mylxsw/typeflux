import Foundation

extension WorkflowController {
    struct DictationPersonaSnapshot {
        let persona: PersonaProfile?
        let prompt: String?
    }

    func promoteRecordingToAuxiliary(context: HotkeyEventContext) {
        if routeComposerVoice(.promote(context.uptime)) { return }
        guard isRecording, recordingIntent == .dictation,
              let decision = recordingGestureDecision else { return }
        recordingUsesAuxiliary = true
        recordingPersonaSnapshot = nil
        if settingsStore.auxiliaryHotkey?.pressCount == 2 {
            recordingMode = .locked
            hotkeyPressedAt = nil
        } else {
            hotkeyPressedAt = context.uptime
        }
        decision.resolve()
    }

    func prepareRecordingGesture(intent: RecordingIntent, startLocked: Bool, auxiliary: Bool) {
        let activation = auxiliary ? settingsStore.auxiliaryHotkey : settingsStore.activationHotkey
        let auxiliaryBinding = settingsStore.auxiliaryHotkey
        let ask = settingsStore.askHotkey
        if !startLocked, intent == .dictation,
           let activation, activation.isModifierOnlyTrigger,
           (ask.map { $0.isModifierDoubleTapTrigger && activation.keyCode == $0.keyCode
               && activation.modifierFlags == $0.modifierFlags } == true
               || (!auxiliary && auxiliaryBinding.map {
                   $0.modifierFlags & activation.modifierFlags == activation.modifierFlags
               } == true)) {
            let decision = RecordingGestureDecision()
            recordingGestureDecision = decision
            decision.schedule(after: Self.tapToLockThreshold)
        }
    }

    func snapshotRecordingPersona(appName: String?, bundleIdentifier: String?) {
        guard recordingPersonaSnapshot == nil else { return }
        let persona = recordingUsesAuxiliary ? settingsStore.auxiliaryPersona
            : settingsStore.effectivePersona(appName: appName, bundleIdentifier: bundleIdentifier)
        recordingPersonaSnapshot = DictationPersonaSnapshot(
            persona: persona,
            prompt: persona.map { settingsStore.resolvedPersonaPrompt(for: $0) }
        )
    }

    func recordingPersona(appName: String?, bundleIdentifier: String?) -> PersonaProfile? {
        if let recordingPersonaSnapshot { return recordingPersonaSnapshot.persona }
        return recordingUsesAuxiliary ? settingsStore.auxiliaryPersona
            : settingsStore.effectivePersona(appName: appName, bundleIdentifier: bundleIdentifier)
    }

}
