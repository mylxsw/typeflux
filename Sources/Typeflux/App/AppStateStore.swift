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
            if self.status != status { self.status = status }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status != status else { return }
                self.status = status
            }
        }
    }
}
