import SwiftUI

public extension EnvironmentValues {
    /// The active window query also invalidates list content whose search binding is supplied by its caller.
    @Entry var typefluxToolbarSearchQuery: String?
}
