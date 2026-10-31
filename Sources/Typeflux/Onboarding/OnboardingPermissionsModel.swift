import Combine
import Foundation

@MainActor
final class OnboardingPermissionsModel: ObservableObject {
    weak var session: OnboardingViewModel?
    let permissions: PermissionsSettingsModel
    private let opensSettings: (SettingsPermission) async -> Bool
    private var subscription: AnyCancellable?
    private var requestTask: Task<Void, Never>?

    @Published var canContinue: Bool? = false
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?
    @Published var optionalExpanded = false
    @Published private(set) var guidePermission: SettingsPermission?
    @Published private(set) var settingsActions: Set<SettingsPermission> = []

    init(session: OnboardingViewModel, service: SettingsPermissionService? = nil,
         opensSettings: ((SettingsPermission) async -> Bool)? = nil) {
        self.session = session
        if let service, let opensSettings {
            permissions = PermissionsSettingsModel(service: service)
            self.opensSettings = opensSettings
        } else {
            let system = OnboardingPermissionsSystem()
            permissions = PermissionsSettingsModel(service: service ?? system.service)
            self.opensSettings = opensSettings ?? system.opensSettings
        }
        // Required status changes update the gate before optional async checks finish.
        subscription = Publishers.Merge(
            permissions.objectWillChange.eraseToAnyPublisher(),
            permissions.$statuses.map { [weak self] statuses in
                self?.updateReadiness(statuses)
            }.eraseToAnyPublisher()
        ).sink { [weak self] in self?.objectWillChange.send() }
    }

    var required: [SettingsPermission] {
        guard let session else { return [] }
        guard session.serviceRoute != .launcherOnly else { return [.accessibility] }
        return [.microphone, .accessibility] + (session.settingsStore.sttProvider == .appleSpeech
            ? [.speechRecognition] : [])
    }

    var optional: [SettingsPermission] {
        SettingsPermission.allCases.filter { !$0.isRequired }
    }

    var requiredGranted: Int {
        required.filter { status($0) == .granted }.count
    }

    var optionalGranted: Int {
        optional.filter { status($0) == .granted }.count
    }

    var nextPending: SettingsPermission? {
        required.first { status($0) != .granted }
    }

    var footerHint: String? {
        let missing = required.count - requiredGranted
        return missing == 0 ? nil : OnboardingStrings.text(
            "missing",
            table: "OnboardingPermissions",
            arguments: [missing]
        )
    }

    func status(_ permission: SettingsPermission) -> SettingsPermissionStatus {
        permissions.statuses[permission] ?? .notGranted
    }

    func refresh() async {
        // Do not race a native prompt with the settings model's refresh guard.
        guard !isBusy else { return }
        await permissions.refresh()
        await updatePresentation()
    }

    private func updatePresentation() async {
        guard !Task.isCancelled else { return }
        for permission in SettingsPermission.allCases {
            if await opensSettings(permission) {
                settingsActions.insert(permission)
            } else {
                settingsActions.remove(permission)
            }
        }
        updateReadiness(permissions.statuses)
    }

    private func updateReadiness(_ statuses: [SettingsPermission: SettingsPermissionStatus]) {
        let required = required
        let loaded = !required.isEmpty && required.allSatisfy { statuses[$0] != nil }
        let ready = loaded && required.allSatisfy { statuses[$0] == .granted }
        if loaded {
            // Keep legacy availability and analytics coherent before enabling continuation.
            let snapshots: [PrivacyGuard.PermissionSnapshot] = required.compactMap { permission in
                permission.corePermission.map {
                    .init(id: $0, state: statuses[permission] == .granted ? .granted : .needsAttention, detail: "")
                }
            }
            if let session, session.permissions != snapshots {
                session.permissions = snapshots
            }
        }
        if canContinue != ready {
            canContinue = ready
        }
    }

    func requestAccess(_ permission: SettingsPermission) {
        guard requestTask == nil, beginRequest(permission) else { return }
        requestTask = Task { [weak self] in
            await self?.performRequest(permission)
            self?.isBusy = false
            self?.requestTask = nil
        }
    }

    func request(_ permission: SettingsPermission) async {
        guard beginRequest(permission) else { return }
        defer { isBusy = false }
        await performRequest(permission)
    }

    private func beginRequest(_ permission: SettingsPermission) -> Bool {
        guard !isBusy, !permissions.isRefreshing, status(permission) != .granted else { return false }
        isBusy = true
        return true
    }

    private func performRequest(_ permission: SettingsPermission) async {
        let opensPane = await opensSettings(permission)
        guard !Task.isCancelled else { return }
        guidePermission = opensPane && permission != .screenRecording ? permission : nil
        await permissions.request(permission)
        await updatePresentation()
        // Screen recording may first show a system prompt, then open its pane.
        if permission == .screenRecording, status(permission) != .granted, !Task.isCancelled {
            guidePermission = permission
        }
    }

    func dismissGuide() {
        guidePermission = nil
    }

    func stop() {
        requestTask?.cancel()
        dismissGuide()
    }

    func monitorGuide() async {
        while guidePermission != nil, !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
        }
    }
}
