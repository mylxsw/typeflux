import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Persona library production views", .serialized, .exclusiveUIState)
@MainActor
struct PersonaLibraryVisualTests {
    @Test func `render states and verify editable definition bounds`() async throws {
        _ = NSApplication.shared
        let priorKeychainMode = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = priorKeychainMode
        let destination = ProcessInfo.processInfo.environment["TYPEFLUX_PERSONA_SNAPSHOTS"]
        if let destination {
            try FileManager.default.createDirectory(
                atPath: destination,
                withIntermediateDirectories: true
            )
        }
        for dark in [false, true] {
            for state in ["builtin", "custom", "create", "apps", "delete", "search", "narrow"] {
                let fixture = try PersonaLibraryFixture()
                defer { fixture.cleanUp() }
                let model = fixture.model
                fixture.store.interfaceStyle = .classic
                model.setInterfaceStyle(.classic)
                fixture.store.appLanguage = .simplifiedChinese
                model.setAppLanguage(.simplifiedChinese)
                let names = ["候选：英文口语化表达", "候选：结构化输出", "候选：英文翻译", "职场助手", "邮件回复", "会议纪要", "代码提交说明"]
                let personas = names.map { PersonaProfile(
                    name: $0,
                    prompt: "Organize the message clearly.\nPreserve the original meaning.\nDo not add facts."
                ) }
                fixture.store.personas = fixture.store.personas.filter(\.isSystem) + personas
                model.personas = fixture.store.personas
                let custom = personas[3]
                fixture.store.savePersonaAppBinding(appIdentifier: "com.apple.mail", personaID: personas[4].id)
                fixture.store.savePersonaAppBinding(appIdentifier: "com.apple.Notes", personaID: custom.id)
                fixture.store.savePersonaAppBinding(appIdentifier: "com.apple.Safari", personaID: nil)
                model.syncPersonaSelectionFromStore(preservingEditor: true)
                model.setPersonaAppBindingEnabled(id: model.personaAppBindings[2].id, isEnabled: false)
                model.setAuxiliaryPersona(personas[0].id.uuidString)
                model.dismissPersonaUndo()
                model.selectPersona(SettingsStore.defaultPersonaID)
                model.appearanceMode = dark ? .dark : .light
                switch state {
                case "custom":
                    model.selectPersona(custom.id)
                    model.personaDraftPrompt += "\nAvoid a closing thank-you."
                case "create":
                    model.beginCreatingPersona(template: SettingsStore.defaultPersonaID, name: "周报助手")
                    model.personaDraftPrompt += "Report progress, plans and risks."
                case "apps":
                    model.selectPersona(custom.id)
                    model.openPersonaAppRules(adding: true, preset: custom.id)
                case "delete":
                    model.selectPersona(custom.id)
                    model.setDefaultPersonaSelection(custom.id)
                    model.setAuxiliaryPersona(custom.id.uuidString)
                    model.dismissPersonaUndo()
                    model.personaPendingDeletion = custom
                case "search":
                    model.searchQuery = "周报"
                default: break
                }
                let size = NSSize(width: state == "narrow" ? 920 : 1180, height: 780)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: StudioView(viewModel: model)
                    .frame(width: size.width, height: size.height))
                host.sizingOptions = []
                host.frame = NSRect(origin: .zero, size: size)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil); window.close() }
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                if ["custom", "create"].contains(state) {
                    let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }
                        .first { $0.string == model.personaDraftPrompt })
                    let scroll = try #require(editor.enclosingScrollView)
                    let rect = host.convert(scroll.bounds, from: scroll)
                    #expect(rect.height > 100)
                    #expect(rect.minY >= 0 && rect.maxY <= size.height)
                    #expect(editor.isEditable)
                }
                if let destination {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 1000)
                    try png
                        .write(to: URL(fileURLWithPath: destination)
                            .appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test func `render empty paused missing and dirty invalid states`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let missing = PersonaAppBinding(appIdentifier: "uninstalled.app", personaID: UUID())
        model.personaAppBindings = [missing]
        model.personaAppBindingsEnabled = false
        model.openPersonaAppRules(adding: true)
        model.personaAppBindingDraftIdentifier = missing.appIdentifier
        let host =
            NSHostingView(rootView: StudioPersonaLibraryView(viewModel: model) { model.personaPendingDeletion = $0 }
                .frame(width: 840, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 500)
        host.layoutSubtreeIfNeeded()
        #expect(model.personaTitle(missing.personaID) == L("settings.personaAppBindings.missingPersona"))
        model.closePersonaAppRules()
        model.personaAppBindings = []
        model.activationHotkey = nil
        model.auxiliaryHotkey = nil
        model.selectPersona(fixture.custom.id)
        model.personaDraftName = ""
        host.layoutSubtreeIfNeeded()
        #expect(!model.canSavePersonaDraft && model.hasPersonaDraftChanges)
        model.beginCreatingPersona()
        model.resolvePersonaDraftGuard(.discard)
        host.layoutSubtreeIfNeeded()
        #expect(model.isCreatingPersonaDraft && !model.canSavePersonaDraft)
        model.cancelPersonaEditing()
        model.openPersonaAppRules()
        host.layoutSubtreeIfNeeded()
        #expect(model.personaAppBindings.isEmpty)
    }

    @Test func `native buttons create save delete and undo`() async throws {
        _ = NSApplication.shared
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudioPersonaLibraryView(viewModel: model) {
            model.personaPendingDeletion = $0
        }.frame(width: 950, height: 650))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        try press("personas.create", in: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isCreatingPersonaDraft)
        model.personaDraftName = "Native created"
        model.personaDraftPrompt = "Keep the meaning."
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.saveDraft", in: window)
        try await Task.sleep(for: .milliseconds(50))
        let persona = try #require(model.selectedPersona)
        #expect(persona.name == "Native created")
        #expect(fixture.store.personas.contains { $0.id == persona.id })
        model.personaDraftPrompt = "New meaning"
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.saveDraft", in: window)
        #expect(fixture.store.personas.first { $0.id == persona.id }?.prompt == "New meaning")
        for decision in [PersonaDraftDecision.save, .discard, .cancel] {
            let pendingPrompt = "Guarded " + String(describing: decision)
            model.personaDraftPrompt = pendingPrompt
            try await Task.sleep(for: .milliseconds(50))
            try press("personas.create", in: window)
            try await Task.sleep(for: .milliseconds(250))
            #expect(model.pendingPersonaNavigation != nil)
            switch decision {
            case .save: try press("personas.guard.save", title: L("personas.redesign.save"), in: window)
            case .discard: try press("personas.guard.discard", title: L("personas.redesign.discard"), in: window)
            case .cancel: try press("personas.guard.cancel", title: L("common.cancel"), in: window)
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.pendingPersonaNavigation == nil)
            if decision == .cancel {
                #expect(!model.isCreatingPersonaDraft && model.personaDraftPrompt == pendingPrompt)
            } else {
                #expect(model.isCreatingPersonaDraft)
            }
            model.cancelPersonaEditing()
            model.selectPersona(persona.id)
        }
        #expect(fixture.store.personas.first { $0.id == persona.id }?.prompt == "Guarded save")
        model.personaPendingDeletion = persona
        try await Task.sleep(for: .milliseconds(250))
        try press("personas.confirmDelete", title: L("common.delete"), in: window)
        #expect(!model.personas.contains { $0.id == persona.id })
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.undoAction", in: window)
        #expect(model.personas.contains { $0.id == persona.id })
        model.searchQuery = "No match"
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.createFromSearch", in: window)
        #expect(model.personaDraftName == "No match")
        model.cancelPersonaEditing()
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.appRules", in: window)
        #expect(model.isPersonaRulesDrawerPresented)
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.rulesEnabled", in: window)
        #expect(!model.personaAppBindingsEnabled)
        try await Task.sleep(for: .milliseconds(50))
        try press("personas.rulesEnabled", in: window)
        #expect(model.personaAppBindingsEnabled)
        try press("personas.closeRules", in: window)
        #expect(!model.isPersonaRulesDrawerPresented)
        model.searchQuery = ""
        try await Task.sleep(for: .milliseconds(50))
        let editorPrompt = model.personaDraftPrompt
        try UnifiedSettingsBehaviorTests.selectPopupItem(L("personas.redesign.none"), model: model, in: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.defaultPersonaSelectionID == nil)
        #expect(model.personaDraftPrompt == editorPrompt)
    }

    private func press(_ identifier: String, title: String? = nil, in window: NSWindow) throws {
        var seen = Set<ObjectIdentifier>()
        func elements(_ element: Any) -> [NSObject] {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            let nativeChildren = (object as? NSView)?.subviews ?? []
            return [object] + children.flatMap(elements) + nativeChildren.flatMap(elements)
        }
        let roots = [window] + (window.childWindows ?? []) + [window.attachedSheet].compactMap(\.self)
        if ProcessInfo.processInfo.environment["TYPEFLUX_PERSONA_AX_DEBUG"] != nil {
            let descriptions = roots.flatMap(elements).compactMap { object -> String? in
                guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
                return object.value(forKey: "accessibilityIdentifier") as? String
            }
            print("PERSONA AX:", descriptions)
            seen.removeAll()
        }
        let target = try #require(roots.flatMap(elements).first {
            if $0.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               $0.value(forKey: "accessibilityIdentifier") as? String == identifier {
                return true
            }
            guard let title, $0.responds(to: NSSelectorFromString("accessibilityTitle")),
                  $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
            return $0.value(forKey: "accessibilityTitle") as? String == title
        }, "Missing native control \(identifier)")
        if let button = (target as? NSButton) ?? ((target as? NSCell)?.controlView as? NSButton) {
            button.performClick(nil)
            return
        }
        if let toggle = target as? NSSwitch {
            toggle.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        #expect(target.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(target.method(for: selector), to: Press.self)
        #expect(action(target, selector))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
