import SwiftUI

@MainActor
final class TypefluxGalleryState: ObservableObject {
    @Published var style: InterfaceStyle = .classic
    @Published var appearance: ColorScheme = .light
}
