import SwiftUI

public enum TypefluxButtonKind: String, CaseIterable, Sendable {
    case primary, regular, destructive, borderless, link

    var role: ButtonRole? { self == .destructive ? .destructive : nil }
}
