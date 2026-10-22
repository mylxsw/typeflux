import Foundation

enum AppStatus: Equatable, Codable, Sendable {
    case idle
    case recording
    case processing
    case failed(message: String)
}

final class AppStateStore: ObservableObject {
    @Published private(set) var status: AppStatus = .idle

    func setStatus(_ status: AppStatus) {
        if Thread.isMainThread {
            self.status = status
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status = status
            }
        }
    }
}
