import SwiftUI

/// Compact sheet body. Hosts that own keyboard routing can disable the sheet's shortcuts.
public struct TypefluxSheet<Content: View>: View {
    private let title: String
    private let cancelTitle: String
    private let confirmTitle: String
    private let cancelShortcut: KeyboardShortcut?
    private let confirmShortcut: KeyboardShortcut?
    private let confirmIdentifier: String
    private let isConfirmEnabled: Bool
    private let scrollsContent: Bool
    private let usesGroupedForm: Bool
    private let role: ButtonRole?
    private let cancelIdentifier: String
    private let cancel: () -> Void
    private let confirm: () -> Void
    private let content: Content

    public init(title: String, cancelTitle: String, confirmTitle: String, isConfirmEnabled: Bool = true,
                scrollsContent: Bool = false, usesGroupedForm: Bool = false,
                role: ButtonRole? = nil, confirmIdentifier: String = "typeflux.sheet.confirm",
                cancelIdentifier: String = "typeflux.sheet.cancel",
                cancelShortcut: KeyboardShortcut? = .cancelAction,
                confirmShortcut: KeyboardShortcut? = .defaultAction, cancel: @escaping () -> Void, confirm: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.confirmIdentifier = confirmIdentifier
        self.cancelShortcut = cancelShortcut
        self.confirmShortcut = confirmShortcut
        self.isConfirmEnabled = isConfirmEnabled
        self.scrollsContent = scrollsContent
        self.usesGroupedForm = usesGroupedForm
        self.role = role
        self.cancelIdentifier = cancelIdentifier
        self.cancel = cancel
        self.confirm = confirm
        self.content = content()
    }

    public var body: some View {
        TypefluxGlassContainer(radius: .sheet, placement: .inWindow) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("typeflux.sheet.title")
                    .padding(.horizontal, chromeInset)
                sheetContent
                HStack(spacing: 8) {
                    Spacer()
                    Button(cancelTitle, role: .cancel, action: cancel).keyboardShortcut(cancelShortcut)
                        .accessibilityIdentifier(cancelIdentifier)
                    Button(confirmTitle, role: role, action: confirm).buttonStyle(.borderedProminent)
                        .keyboardShortcut(confirmShortcut).disabled(!isConfirmEnabled)
                        .accessibilityIdentifier(confirmIdentifier)
                }
                .padding(.horizontal, chromeInset)
            }.padding(20)
        }
    }

    // Native grouped forms inset their cards another 20 points inside the form's bounds.
    private var chromeInset: CGFloat { usesGroupedForm ? 20 : 0 }

    @ViewBuilder private var sheetContent: some View {
        if scrollsContent {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxHeight: 360)
        } else {
            content
        }
    }
}

public extension View {
    /// Return false from confirm to keep validation errors visible in the sheet.
    func typefluxSheet(isPresented: Binding<Bool>, configuration: TypefluxSheetConfiguration,
                       confirm: @escaping () -> Bool,
                       @ViewBuilder content: @escaping () -> some View) -> some View {
        sheet(isPresented: isPresented) {
            TypefluxSheet(title: configuration.title, cancelTitle: configuration.cancelTitle,
                          confirmTitle: configuration.confirmTitle,
                          isConfirmEnabled: configuration.isConfirmEnabled, role: configuration.role,
                          cancel: { isPresented.wrappedValue = false },
                          confirm: {
                              if confirm() {
                                  isPresented.wrappedValue = false
                              }
                          }, content: content)
        }
    }
}
