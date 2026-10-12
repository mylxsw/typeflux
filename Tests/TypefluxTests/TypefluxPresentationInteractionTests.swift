import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite(.serialized, .exclusiveUIState,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_UI_NAVIGATION_LIVE"] == "1"))
@MainActor
struct TypefluxPresentationInteractionTests {
    private final class State: ObservableObject {
        @Published var sheet = false
        @Published var alert = false
        @Published var dialog = false
        @Published var enabled = false
        @Published var valid = false
        @Published var text = ""
        var attempts = 0
        var deletions = 0
    }

    private struct Root: View {
        @ObservedObject var state: State

        var body: some View {
            VStack {
                Button("Open sheet") { state.sheet = true }
                Button("Open alert") { state.alert = true }
                Button("Open dialog") { state.dialog = true }
            }
            .typefluxSheet(isPresented: $state.sheet,
                           configuration: TypefluxSheetConfiguration(title: "Add item", cancelTitle: "Cancel",
                                                                     confirmTitle: "Add",
                                                                     isConfirmEnabled: state.enabled),
                           confirm: {
                               state.attempts += 1
                               return state.valid
                           }, content: {
                               TextField("Name", text: $state.text).frame(width: 280)
                           })
            .typefluxAlert(confirmation, isPresented: $state.alert) { state.deletions += 1 }
            .typefluxConfirmationDialog(confirmation, isPresented: $state.dialog) { state.deletions += 1 }
        }

        private var confirmation: TypefluxConfirmation {
            TypefluxConfirmation(title: "Delete item?", message: "Cannot be undone", confirmTitle: "Delete",
                                 cancelTitle: "Cancel", role: .destructive)
        }
    }

    @Test func `sheet footer handles disabled confirm validation default action and cancellation`() async throws {
        let state = State()
        try await TypefluxNavigationTestSupport.withWindow(Root(state: state)) { window, host in
            try SettingsBehaviorTestSupport.button("Open sheet", in: host).press()
            try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains("Add", in: sheet) }
            let cancel = try SettingsBehaviorTestSupport.button("Cancel", in: sheet)
            let confirm = try SettingsBehaviorTestSupport.button("Add", in: sheet)
            #expect(cancel.frame.minX < confirm.frame.minX)
            #expect(confirm.value("isAccessibilityEnabled") as? Bool == false)
            try TypefluxNavigationTestSupport.sendKey(36, to: sheet, keyEquivalent: true)
            #expect(state.attempts == 0 && state.sheet)
            state.enabled = true
            try await SettingsBehaviorTestSupport.wait {
                (try? SettingsBehaviorTestSupport.button("Add", in: sheet).value("isAccessibilityEnabled") as? Bool) ==
                    true
            }
            try SettingsBehaviorTestSupport.button("Add", in: sheet).press()
            #expect(state.attempts == 1 && state.sheet)
            state.valid = true
            try TypefluxNavigationTestSupport.sendKey(36, to: sheet, keyEquivalent: true)
            try await SettingsBehaviorTestSupport.wait { !state.sheet && window.attachedSheet == nil }
            #expect(state.attempts == 2)
            try SettingsBehaviorTestSupport.button("Open sheet", in: host).press()
            try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
            try TypefluxNavigationTestSupport.sendKey(53, to: #require(window.attachedSheet), keyEquivalent: true)
            try await SettingsBehaviorTestSupport.wait { !state.sheet && window.attachedSheet == nil }
        }
    }

    @Test func `native alert and confirmation dialog use cancel and destructive actions`() async throws {
        let state = State()
        try await TypefluxNavigationTestSupport.withWindow(Root(state: state)) { window, host in
            for title in ["Open alert", "Open dialog"] {
                try SettingsBehaviorTestSupport.button(title, in: host).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let presented = try #require(window.attachedSheet)
                try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(
                    "Delete",
                    in: presented
                ) }
                try SettingsBehaviorTestSupport.button("Cancel", in: presented).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                #expect(state.deletions == (title == "Open alert" ? 0 : 1))
                try SettingsBehaviorTestSupport.button(title, in: host).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let next = try #require(window.attachedSheet)
                try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains("Delete", in: next) }
                try SettingsBehaviorTestSupport.button("Delete", in: next).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
            }
            #expect(state.deletions == 2)
        }
    }

    @Test func `gallery buttons present sheet alert dialog HUD and window template`() async throws {
        let labels = TypefluxNavigationGalleryExamples.labels
        let gallery = TypefluxNavigationGallery(labels: labels, items: TypefluxNavigationGalleryExamples.items,
                                                modes: TypefluxNavigationGalleryExamples.modes)
        try await TypefluxNavigationTestSupport.withWindow(
            gallery.padding(24),
            size: NSSize(width: 1100, height: 1080)
        ) { window, host in
            for title in [labels.sheet, labels.alert, labels.dialog, labels.window] {
                try SettingsBehaviorTestSupport.button(title, in: host).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                if title == labels.sheet {
                    try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(
                        labels.confirm,
                        in: sheet
                    ) }
                    try SettingsBehaviorTestSupport.button(labels.confirm, in: sheet).press()
                } else if title == labels.alert || title == labels.dialog {
                    try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(
                        labels.cancel,
                        in: sheet
                    ) }
                    try SettingsBehaviorTestSupport.button(
                        title == labels.alert ? labels.delete : labels.cancel,
                        in: sheet
                    ).press()
                } else {
                    try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(
                        labels.cancel,
                        in: sheet
                    ) }
                    try SettingsBehaviorTestSupport.button(labels.cancel, in: sheet).press()
                }
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
            }
            try SettingsBehaviorTestSupport.button(labels.hud, in: host).press()
            #expect(SettingsBehaviorTestSupport.contains(labels.copied, in: host))
        }
    }
}
