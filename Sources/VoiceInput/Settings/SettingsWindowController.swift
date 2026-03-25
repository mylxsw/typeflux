import AppKit
import SwiftUI

final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(settingsStore: SettingsStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settingsStore: settingsStore)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput Settings"
        window.center()
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SettingsView: View {
    @State private var sttProvider: STTProvider
    @State private var llmProvider: LLMProvider

    @State private var llmBaseURL: String
    @State private var llmModel: String
    @State private var llmAPIKey: String

    @State private var ollamaBaseURL: String
    @State private var ollamaModel: String
    @State private var ollamaAutoSetup: Bool
    @State private var ollamaStatus: String = "Local model has not been prepared yet."
    @State private var isPreparingOllama = false

    @State private var whisperBaseURL: String
    @State private var whisperModel: String
    @State private var whisperAPIKey: String

    @State private var enableFn: Bool
    @State private var appleSpeechFallback: Bool

    @State private var personaRewriteEnabled: Bool
    @State private var personas: [PersonaProfile]
    @State private var selectedPersonaID: UUID?

    @State private var customHotkeys: [HotkeyBinding]
    @StateObject private var recorder = HotkeyRecorder()
    @StateObject private var errorLogStore = ErrorLogStore.shared

    private let settingsStore: SettingsStore
    private let modelManager = OllamaLocalModelManager()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore

        let currentPersonas = settingsStore.personas
        let initialPersonaID = settingsStore.activePersona.map(\.id) ?? currentPersonas.first?.id

        _sttProvider = State(initialValue: settingsStore.sttProvider)
        _llmProvider = State(initialValue: settingsStore.llmProvider)

        _llmBaseURL = State(initialValue: settingsStore.llmBaseURL)
        _llmModel = State(initialValue: settingsStore.llmModel)
        _llmAPIKey = State(initialValue: settingsStore.llmAPIKey)

        _ollamaBaseURL = State(initialValue: settingsStore.ollamaBaseURL)
        _ollamaModel = State(initialValue: settingsStore.ollamaModel)
        _ollamaAutoSetup = State(initialValue: settingsStore.ollamaAutoSetup)

        _whisperBaseURL = State(initialValue: settingsStore.whisperBaseURL)
        _whisperModel = State(initialValue: settingsStore.whisperModel)
        _whisperAPIKey = State(initialValue: settingsStore.whisperAPIKey)

        _enableFn = State(initialValue: settingsStore.enableFnHotkey)
        _appleSpeechFallback = State(initialValue: settingsStore.useAppleSpeechFallback)

        _personaRewriteEnabled = State(initialValue: settingsStore.personaRewriteEnabled)
        _personas = State(initialValue: currentPersonas)
        _selectedPersonaID = State(initialValue: initialPersonaID)

        _customHotkeys = State(initialValue: settingsStore.customHotkeys)
    }

    var body: some View {
        TabView {
            hotkeyTab
                .tabItem { Text("Hotkey") }
            sttTab
                .tabItem { Text("STT") }
            llmTab
                .tabItem { Text("LLM") }
            personasTab
                .tabItem { Text("Personas") }
            errorLogTab
                .tabItem {
                    HStack {
                        Text("Errors")
                        if !errorLogStore.entries.isEmpty {
                            Text("(\(errorLogStore.entries.count))")
                                .foregroundColor(.red)
                        }
                    }
                }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 620)
    }

    private var hotkeyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkey")
                .font(.title2)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Right Command (press-and-hold, temporary debug override)", isOn: $enableFn)
                        .onChange(of: enableFn) { settingsStore.enableFnHotkey = $0 }

                    HStack {
                        Button(recorder.isRecording ? "Recording…" : "Add Custom Hotkey") {
                            if recorder.isRecording {
                                recorder.stop()
                            } else {
                                recorder.start { binding in
                                    var list = customHotkeys
                                    if !list.contains(where: { $0.keyCode == binding.keyCode && $0.modifierFlags == binding.modifierFlags }) {
                                        list.append(binding)
                                        customHotkeys = list
                                        settingsStore.customHotkeys = list
                                    }
                                }
                            }
                        }

                        Text("Press a key with modifiers (⌘/⌥/⌃/⇧) to record")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if customHotkeys.isEmpty {
                        Text("No custom hotkeys yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        List {
                            ForEach(customHotkeys) { binding in
                                HStack {
                                    Text(HotkeyFormat.display(binding))
                                    Spacer()
                                    Button("Remove") {
                                        customHotkeys.removeAll { $0.id == binding.id }
                                        settingsStore.customHotkeys = customHotkeys
                                    }
                                }
                            }
                        }
                        .frame(height: 180)
                    }
                }
                .padding(6)
            } label: {
                Text("Bindings")
            }

            Spacer()
        }
    }

    private var sttTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speech To Text")
                    .font(.title2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Provider", selection: $sttProvider) {
                            ForEach(STTProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: sttProvider) { settingsStore.sttProvider = $0 }

                        Toggle("Enable Apple Speech fallback when Whisper is unavailable", isOn: $appleSpeechFallback)
                            .onChange(of: appleSpeechFallback) { settingsStore.useAppleSpeechFallback = $0 }
                    }
                    .padding(6)
                } label: {
                    Text("Provider")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Whisper Base URL", text: $whisperBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: whisperBaseURL) { settingsStore.whisperBaseURL = $0 }
                        TextField("Whisper Model", text: $whisperModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: whisperModel) { settingsStore.whisperModel = $0 }
                        SecureField("Whisper API Key (optional for local gateway)", text: $whisperAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: whisperAPIKey) { settingsStore.whisperAPIKey = $0 }

                        Text("Use this for OpenAI Whisper or any OpenAI-compatible transcription service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                } label: {
                    Text("Whisper / OpenAI-Compatible")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apple Speech runs on-device and is useful as a local fallback or a primary offline-ish option.")
                            .font(.callout)
                        Text("If you pick Apple Speech as the STT provider, the app will skip Whisper and transcribe locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                } label: {
                    Text("Apple Speech")
                }
            }
        }
    }

    private var llmTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("LLM")
                    .font(.title2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Provider", selection: $llmProvider) {
                            ForEach(LLMProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: llmProvider) { settingsStore.llmProvider = $0 }

                        Text("Persona rewriting and voice-driven editing will use the selected provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                } label: {
                    Text("Provider")
                }

                if llmProvider == .openAICompatible {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Base URL", text: $llmBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: llmBaseURL) { settingsStore.llmBaseURL = $0 }
                            TextField("Model", text: $llmModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: llmModel) { settingsStore.llmModel = $0 }
                            SecureField("API Key (optional for local gateways)", text: $llmAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: llmAPIKey) { settingsStore.llmAPIKey = $0 }
                        }
                        .padding(6)
                    } label: {
                        Text("OpenAI-Compatible Chat")
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Ollama Base URL", text: $ollamaBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: ollamaBaseURL) { settingsStore.ollamaBaseURL = $0 }
                            TextField("Local Model", text: $ollamaModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: ollamaModel) { settingsStore.ollamaModel = $0 }

                            Toggle("Automatically install/start Ollama and pull the model", isOn: $ollamaAutoSetup)
                                .onChange(of: ollamaAutoSetup) { settingsStore.ollamaAutoSetup = $0 }

                            HStack {
                                Button(isPreparingOllama ? "Preparing…" : "Prepare Local Model") {
                                    prepareOllamaModel()
                                }
                                .disabled(isPreparingOllama)

                                Text(ollamaStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                    } label: {
                        Text("Local Ollama")
                    }
                }
            }
        }
    }

    private var personasTab: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable persona-based rewriting", isOn: $personaRewriteEnabled)
                    .onChange(of: personaRewriteEnabled) { settingsStore.personaRewriteEnabled = $0 }

                HStack {
                    Button("Add Persona") {
                        addPersona()
                    }

                    Button("Delete") {
                        deleteSelectedPersona()
                    }
                    .disabled(selectedPersona == nil)
                }

                List(selection: $selectedPersonaID) {
                    ForEach(personas) { persona in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(persona.name)
                                Text(persona.prompt)
                                    .lineLimit(2)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if settingsStore.activePersonaID == persona.id.uuidString {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .tag(Optional(persona.id))
                    }
                }
            }
            .frame(minWidth: 250)
            .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 12) {
                Text("Persona Editor")
                    .font(.title3)

                if let selectedPersona {
                    TextField(
                        "Persona Name",
                        text: Binding(
                            get: { selectedPersona.name },
                            set: { updateSelectedPersona(name: $0, prompt: selectedPersona.prompt) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    TextEditor(
                        text: Binding(
                            get: { selectedPersona.prompt },
                            set: { updateSelectedPersona(name: selectedPersona.name, prompt: $0) }
                        )
                    )
                    .font(.body)
                    .frame(minHeight: 240)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )

                    HStack {
                        Button("Set Active") {
                            settingsStore.activePersonaID = selectedPersona.id.uuidString
                        }

                        if settingsStore.activePersonaID == selectedPersona.id.uuidString {
                            Button("Deactivate") {
                                settingsStore.personaRewriteEnabled = false
                                personaRewriteEnabled = false
                            }
                        }
                    }

                    Text("When enabled, raw transcription can be polished by this persona. If text is selected, spoken instructions and persona rules are applied together.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()
                    Text("Select or create a persona to start editing.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(minWidth: 380)
        }
        .padding(.vertical, 6)
        .onChange(of: selectedPersonaID) { newValue in
            if settingsStore.activePersonaID.isEmpty, let newValue {
                settingsStore.activePersonaID = newValue.uuidString
            }
        }
    }

    private var errorLogTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Error Log")
                    .font(.title2)
                Spacer()
                Button("Clear") {
                    errorLogStore.clear()
                }
                .disabled(errorLogStore.entries.isEmpty)
            }

            if errorLogStore.entries.isEmpty {
                VStack {
                    Spacer()
                    Text("No errors recorded")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(errorLogStore.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var selectedPersona: PersonaProfile? {
        guard let selectedPersonaID else { return nil }
        return personas.first { $0.id == selectedPersonaID }
    }

    private func addPersona() {
        let persona = PersonaProfile(name: "新建人设", prompt: "请按这个人设风格重写文本。")
        personas.append(persona)
        settingsStore.personas = personas
        selectedPersonaID = persona.id

        if settingsStore.activePersonaID.isEmpty {
            settingsStore.activePersonaID = persona.id.uuidString
        }
    }

    private func deleteSelectedPersona() {
        guard let selectedPersonaID else { return }
        personas.removeAll { $0.id == selectedPersonaID }
        settingsStore.personas = personas

        if settingsStore.activePersonaID == selectedPersonaID.uuidString {
            settingsStore.activePersonaID = personas.first?.id.uuidString ?? ""
        }

        self.selectedPersonaID = personas.first?.id
    }

    private func updateSelectedPersona(name: String, prompt: String) {
        guard let selectedPersonaID, let index = personas.firstIndex(where: { $0.id == selectedPersonaID }) else { return }
        personas[index].name = name
        personas[index].prompt = prompt
        settingsStore.personas = personas
    }

    private func prepareOllamaModel() {
        isPreparingOllama = true
        ollamaStatus = "Preparing local model..."

        Task {
            do {
                settingsStore.ollamaBaseURL = ollamaBaseURL
                settingsStore.ollamaModel = ollamaModel
                settingsStore.ollamaAutoSetup = ollamaAutoSetup
                try await modelManager.ensureModelReady(settingsStore: settingsStore)
                await MainActor.run {
                    isPreparingOllama = false
                    ollamaStatus = "Local model is ready."
                }
            } catch {
                await MainActor.run {
                    isPreparingOllama = false
                    ollamaStatus = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
