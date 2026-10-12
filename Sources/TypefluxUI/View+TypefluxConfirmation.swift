import SwiftUI

public extension View {
    func typefluxAlert(_ confirmation: TypefluxConfirmation, isPresented: Binding<Bool>,
                       confirm: @escaping () -> Void) -> some View {
        alert(confirmation.title, isPresented: isPresented) {
            Button(confirmation.cancelTitle, role: .cancel) {}
            Button(confirmation.confirmTitle, role: confirmation.role, action: confirm)
        } message: {
            Text(confirmation.message)
        }
    }

    func typefluxConfirmationDialog(_ confirmation: TypefluxConfirmation, isPresented: Binding<Bool>,
                                    confirm: @escaping () -> Void) -> some View {
        confirmationDialog(confirmation.title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmation.cancelTitle, role: .cancel) {}
            Button(confirmation.confirmTitle, role: confirmation.role, action: confirm)
        } message: {
            Text(confirmation.message)
        }
    }
}
