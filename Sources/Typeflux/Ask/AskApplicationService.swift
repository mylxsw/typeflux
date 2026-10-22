import Foundation

/// One production API graph for all windows. In particular, a fallback workflow
/// assistant must not cache a second engine or create another account sync loop.
@MainActor
final class AskApplicationService {
    nonisolated static let shared = AskApplicationService()
    private var instance: AskApplicationAPI?

    // Construction is inert; resolving or mutating the API remains main-actor isolated.
    nonisolated init() {}

    func resolve(create: () -> AskApplicationAPI) -> AskApplicationAPI {
        if let instance { return instance }
        let value = create()
        instance = value
        return value
    }
}
