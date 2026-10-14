import SwiftUI

/// Allows snapshots of the same components presented by the native controller.
struct ScreenRecordingView: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    var close: () -> Void
    var chooseDirectory: () -> Void
    var body: some View {
        switch model.state {
        case .preview, .exporting:
            ScreenRecordingPreviewView(model: model, close: close, chooseDirectory: chooseDirectory)
        case .recording, .paused, .starting, .stopping:
            ScreenRecordingCapsule(model: model, close: close)
        default:
            ScreenRecordingToolbar(model: model, close: close, chooseDirectory: chooseDirectory)
        }
    }
}

/// Native screen recording uses the same red as the approved capture controls.
enum ScreenRecordingAppearance {
    static let record = Color(red: 1, green: 59 / 255, blue: 48 / 255)
}
