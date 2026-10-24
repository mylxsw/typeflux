import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Speech

enum PrivacyGuard {
    static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    enum PermissionID: String, CaseIterable, Identifiable {
        case microphone
        case speechRecognition
        case accessibility

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .microphone:
                L("permission.microphone.title")
            case .speechRecognition:
                L("permission.speechRecognition.title")
            case .accessibility:
                L("permission.accessibility.title")
            }
        }

        var summary: String {
            switch self {
            case .microphone:
                L("permission.microphone.summary")
            case .speechRecognition:
                L("permission.speechRecognition.summary")
            case .accessibility:
                L("permission.accessibility.summary")
            }
        }
    }

    enum PermissionState: Equatable {
        case granted
        case needsAttention
    }

    struct PermissionSnapshot: Identifiable, Equatable {
        let id: PermissionID
        let state: PermissionState
        private let detailSource: DetailSource

        enum DetailSource: Equatable {
            case localizedKey(String)
            case literal(String)
        }

        init(id: PermissionID, state: PermissionState, detailKey: String) {
            self.id = id
            self.state = state
            detailSource = .localizedKey(detailKey)
        }

        init(id: PermissionID, state: PermissionState, detail: String) {
            self.id = id
            self.state = state
            detailSource = .literal(detail)
        }

        var title: String {
            id.title
        }

        var summary: String {
            id.summary
        }

        var detail: String {
            switch detailSource {
            case let .localizedKey(key):
                L(key)
            case let .literal(detail):
                detail
            }
        }

        var isGranted: Bool {
            state == .granted
        }

        var badgeText: String {
            isGranted ? L("permission.badge.granted") : L("permission.badge.required")
        }

        var actionTitle: String {
            isGranted ? L("permission.action.openSettings") : L("permission.action.grantAccess")
        }
    }

    @MainActor
    static func snapshot(for id: PermissionID) -> PermissionSnapshot {
        switch id {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            return PermissionSnapshot(
                id: id,
                state: status == .authorized ? .granted : .needsAttention,
                detailKey: microphoneDetailKey(for: status)
            )

        case .speechRecognition:
            let status = SFSpeechRecognizer.authorizationStatus()
            return PermissionSnapshot(
                id: id,
                state: status == .authorized ? .granted : .needsAttention,
                detailKey: speechRecognitionDetailKey(for: status)
            )

        case .accessibility:
            let trusted = isAccessibilityGranted()
            return PermissionSnapshot(
                id: id,
                state: trusted ? .granted : .needsAttention,
                detailKey: trusted
                    ? "permission.accessibility.detail.granted"
                    : "permission.accessibility.detail.required"
            )
        }
    }

    @MainActor
    static func snapshots() -> [PermissionSnapshot] {
        PermissionID.allCases.map(snapshot(for:))
    }

    /// Returns true if requesting this permission will show an in-app system dialog
    /// (rather than opening System Preferences). Used to decide whether to re-activate
    /// the app window after the dialog is dismissed.
    @MainActor
    static func willShowInAppDialog(for id: PermissionID) -> Bool {
        switch id {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speechRecognition:
            SFSpeechRecognizer.authorizationStatus() == .notDetermined
        case .accessibility:
            false
        }
    }

    @MainActor
    static func requestPermission(_ id: PermissionID) async {
        switch id {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:
                await openPermissionSettings(for: id)
            case .notDetermined:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted:
                await openPermissionSettings(for: id)
            @unknown default:
                await openPermissionSettings(for: id)
            }

        case .speechRecognition:
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized:
                await openPermissionSettings(for: id)
            case .notDetermined:
                _ = await requestSpeechAuthorization()
            case .denied, .restricted:
                await openPermissionSettings(for: id)
            @unknown default:
                await openPermissionSettings(for: id)
            }

        case .accessibility:
            if isAccessibilityGranted() {
                await openPermissionSettings(for: id)
            } else {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                await openPermissionSettings(for: id)
            }
        }
    }

    @MainActor
    static func openPermissionSettings(for id: PermissionID) async {
        guard let url = permissionSettingsURL(for: id) else { return }
        PermissionGuidanceService.shared.open(url)
    }

    private static func permissionSettingsURL(for id: PermissionID) -> URL? {
        switch id {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognition:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    static func isAccessibilityGranted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func microphoneDetailKey(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "permission.microphone.detail.authorized"
        case .notDetermined:
            return "permission.microphone.detail.notDetermined"
        case .denied:
            return "permission.microphone.detail.denied"
        case .restricted:
            return "permission.microphone.detail.restricted"
        @unknown default:
            return "permission.microphone.detail.unknown"
        }
    }

    private static func speechRecognitionDetailKey(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "permission.speechRecognition.detail.authorized"
        case .notDetermined:
            return "permission.speechRecognition.detail.notDetermined"
        case .denied:
            return "permission.speechRecognition.detail.denied"
        case .restricted:
            return "permission.speechRecognition.detail.restricted"
        @unknown default:
            return "permission.speechRecognition.detail.unknown"
        }
    }

    @MainActor
    static func requiredPermissionIDs(settingsStore: SettingsStore) -> [PermissionID] {
        var required: [PermissionID] = [
            .microphone,
            .accessibility
        ]

        if settingsStore.sttProvider == .appleSpeech || settingsStore.useAppleSpeechFallback {
            required.append(.speechRecognition)
        }

        return required
    }

    @MainActor
    static func requiredSnapshots(settingsStore: SettingsStore) -> [PermissionSnapshot] {
        requiredPermissionIDs(settingsStore: settingsStore).map(snapshot(for:))
    }

    @MainActor
    static func missingRequiredSnapshots(settingsStore: SettingsStore) -> [PermissionSnapshot] {
        requiredSnapshots(settingsStore: settingsStore).filter { !$0.isGranted }
    }

    @MainActor
    static func openSettingsForPermissions(_ ids: [PermissionID]) {
        let urls = ids.compactMap(permissionSettingsURL(for:))
        for (index, url) in urls.enumerated() {
            let delay = DispatchTime.now() + .milliseconds(index * 250)
            DispatchQueue.main.asyncAfter(deadline: delay) {
                PermissionGuidanceService.shared.open(url)
            }
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
