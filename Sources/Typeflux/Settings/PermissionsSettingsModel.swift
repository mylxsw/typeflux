import SwiftUI

@MainActor
final class PermissionsSettingsModel: ObservableObject {
    @Published private(set) var statuses: [SettingsPermission: SettingsPermissionStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var requestingPermission: SettingsPermission?
    @Published private(set) var requestError: SettingsPermission?

    private let service: SettingsPermissionService
    private var refreshPending = false

    init(service: SettingsPermissionService? = nil) {
        self.service = service ?? .system()
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            for permission in SettingsPermission.allCases {
                let status = await service.status(permission)
                guard !Task.isCancelled else { return }
                statuses[permission] = status
            }
        } while refreshPending
    }

    func request(_ permission: SettingsPermission) async {
        guard requestingPermission == nil, !isRefreshing else { return }
        requestingPermission = permission
        requestError = nil
        defer { requestingPermission = nil }
        do {
            try await service.request(permission)
        } catch is CancellationError {
            return
        } catch {
            requestError = permission
        }
        await refresh()
    }
}
