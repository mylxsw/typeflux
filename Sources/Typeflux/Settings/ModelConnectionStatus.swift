import SwiftUI

struct ModelConnectionStatus: View {
    let connected: Bool

    var body: some View {
        TypefluxStatus(L(connected ? "models.configured" : "models.notConfigured"),
                       tone: connected ? .success : .inactive)
    }
}
