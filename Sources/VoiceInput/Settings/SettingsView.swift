import SwiftUI

struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        StudioShell(
            currentSection: viewModel.currentSection,
            onSelect: viewModel.navigate,
            searchText: $viewModel.searchQuery,
            searchPlaceholder: viewModel.currentSection.searchPlaceholder
        ) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.heroSection) {
                StudioHeroHeader(
                    eyebrow: viewModel.currentSection.eyebrow,
                    title: viewModel.currentSection.heading,
                    subtitle: viewModel.currentSection.subheading
                )

                currentPage
            }
        }
        .preferredColorScheme(viewModel.preferredColorScheme)
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, StudioTheme.Insets.toastHorizontal)
                    .padding(.vertical, StudioTheme.Insets.toastVertical)
                    .background(
                        Capsule()
                            .fill(StudioTheme.surface)
                    )
                    .overlay(Capsule().stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin))
                    .padding(.bottom, StudioTheme.Insets.toastBottom)
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch viewModel.currentSection {
        case .home:
            homePage
        case .models:
            modelsPage
        case .personas:
            personasPage
        case .history:
            historyPage
        case .debug:
            debugPage
        case .settings:
            settingsPage
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    Text("Press and hold your shortcut to start dictation, then release to finish.")
                        .font(.studioBody(StudioTheme.Typography.bodyLarge))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

                Spacer()

                StudioButton(title: "Popular use cases", systemImage: "arrow.up.right", variant: .secondary) {
                    viewModel.navigate(to: .settings)
                }
            }

            overviewPanel

            HStack(spacing: StudioTheme.Spacing.large) {
                accentPromoCard(
                    title: "Recommended workflow",
                    description: "Use a persona to keep punctuation, tone, and wording consistent across apps.",
                    buttonTitle: "Open Personas",
                    colors: [
                        StudioTheme.Colors.promoWorkflowStart,
                        StudioTheme.Colors.promoWorkflowEnd
                    ]
                ) {
                    viewModel.navigate(to: .personas)
                }

                accentPromoCard(
                    title: "Refine your setup",
                    description: "Review models, fallback behavior, and appearance from a single settings surface.",
                    buttonTitle: "Open Settings",
                    colors: [
                        StudioTheme.Colors.promoSetupStart,
                        StudioTheme.Colors.promoSetupEnd
                    ]
                ) {
                    viewModel.navigate(to: .settings)
                }
            }

            sectionHeader(
                title: "Recent Transcriptions",
                primaryButtonTitle: "Open Settings",
                primaryAction: { viewModel.navigate(to: .settings) },
                secondaryButtonTitle: "Export All",
                secondaryAction: { viewModel.exportHistory() }
            )

            sessionStream(records: Array(viewModel.displayedHistory.prefix(StudioTheme.Count.homeRecentRecords)))
        }
    }

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ForEach(StudioModelDomain.allCases) { domain in
                    Button {
                        viewModel.setModelDomain(domain)
                    } label: {
                        Text(modelDomainTabTitle(for: domain))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                        .foregroundStyle(viewModel.modelDomain == domain ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .padding(.horizontal, StudioTheme.Insets.segmentedItemHorizontal)
                        .padding(.vertical, StudioTheme.Insets.segmentedItemVertical)
                        .background(
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedItem, style: .continuous)
                                .fill(viewModel.modelDomain == domain ? StudioTheme.surface : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedItem, style: .continuous))
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                }
            }
            .padding(.horizontal, StudioTheme.Insets.segmentedControlHorizontal)
            .padding(.vertical, StudioTheme.Insets.segmentedControlVertical)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedControl, style: .continuous)
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.segmentedControlFill))
            )
            .frame(minHeight: StudioTheme.Layout.modelTabsMinHeight, alignment: .leading)

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    StudioSectionTitle(title: "Architecture Mode")
                    Text(viewModel.currentArchitectureTitle)
                        .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(viewModel.currentArchitectureDescription)
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)

                    VStack(spacing: StudioTheme.Spacing.medium) {
                        architectureModeButton(title: "Local Processing", subtitle: "On-device privacy", isActive: isLocalArchitecture)
                        architectureModeButton(title: "Remote API", subtitle: "High-performance cloud", isActive: !isLocalArchitecture)
                    }
                }
                .frame(width: StudioTheme.Layout.modelsArchitectureCardWidth)

                VStack(spacing: StudioTheme.Spacing.xxLarge) {
                    HStack(spacing: StudioTheme.Spacing.xxLarge) {
                        ForEach(viewModel.architectureCards) { card in
                            modelCard(card)
                        }
                    }

                    HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                        parameterCard
                        actionCard
                    }
                }
            }

            HStack {
                Spacer()
                StudioButton(title: "Reset Changes", systemImage: nil, variant: .secondary) {
                    viewModel.navigate(to: .models)
                }
                StudioButton(title: "Apply Configuration", systemImage: "bolt.fill", variant: .primary) {
                    viewModel.applyModelConfiguration()
                }
            }
        }
    }

    private func modelDomainTabTitle(for domain: StudioModelDomain) -> String {
        switch domain {
        case .stt:
            return "听写"
        case .llm:
            return "问任何问题"
        }
    }

    private var personasPage: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.section) {
            StudioCard {
                HStack {
                    Text("Persona Roster")
                        .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer()
                    Button(action: viewModel.addPersona) {
                        Image(systemName: "plus")
                            .foregroundStyle(.white)
                            .frame(width: StudioTheme.ControlSize.personaAddButton, height: StudioTheme.ControlSize.personaAddButton)
                            .background(Circle().fill(StudioTheme.accent))
                            .contentShape(Circle())
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                }

                VStack(spacing: StudioTheme.Spacing.smallMedium) {
                    ForEach(viewModel.filteredPersonas) { persona in
                        Button {
                            viewModel.selectPersona(persona.id)
                        } label: {
                            HStack(spacing: StudioTheme.Spacing.medium) {
                                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                    .fill(StudioTheme.accentSoft)
                                    .frame(width: StudioTheme.ControlSize.personaAvatar, height: StudioTheme.ControlSize.personaAvatar)
                                    .overlay(
                                        Text(String(persona.name.prefix(StudioTheme.Count.personaInitials)).uppercased())
                                            .font(.studioBody(StudioTheme.Typography.body, weight: .bold))
                                            .foregroundStyle(StudioTheme.accent)
                                    )
                                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                                    Text(persona.name)
                                        .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                    Text(persona.prompt)
                                        .font(.studioBody(StudioTheme.Typography.caption))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .lineLimit(StudioTheme.LineLimit.personaPrompt)
                                }
                                Spacer()
                                Circle()
                                    .fill(persona.id.uuidString == viewModel.activePersonaID ? StudioTheme.accent : Color.clear)
                                    .frame(width: StudioTheme.ControlSize.personaStatusDot, height: StudioTheme.ControlSize.personaStatusDot)
                            }
                            .padding(StudioTheme.Insets.personaRow)
                            .background(
                                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xxLarge, style: .continuous)
                                    .fill(viewModel.selectedPersonaID == persona.id ? StudioTheme.surfaceMuted : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xxLarge, style: .continuous))
                        }
                        .buttonStyle(StudioInteractiveButtonStyle())
                    }
                }
            }
            .frame(width: StudioTheme.Layout.personasListWidth)

            StudioCard {
                HStack {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                        Text("Editing Active Persona")
                            .font(.studioBody(StudioTheme.Typography.sidebarEyebrow, weight: .bold))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text(viewModel.selectedPersona?.name ?? "No Persona Selected")
                            .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                    }
                    Spacer()
                    StudioButton(title: "Discard", systemImage: nil, variant: .secondary) {
                        viewModel.refreshHistory()
                    }
                    StudioButton(title: "Save Changes", systemImage: nil, variant: .primary) {
                        viewModel.applyModelConfiguration()
                    }
                }

                Divider().overlay(StudioTheme.border)

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSectionTitle(title: "Core Identity")
                    StudioTextInputCard(
                        label: "Persona Name",
                        placeholder: "Enter persona name",
                        text: Binding(
                            get: { viewModel.selectedPersonaName },
                            set: { viewModel.selectedPersonaName = $0 }
                        )
                    )
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    HStack {
                        StudioSectionTitle(title: "System Prompt")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { viewModel.personaRewriteEnabled },
                            set: viewModel.setPersonaRewriteEnabled
                        ))
                        .toggleStyle(.switch)
                    }

                    TextEditor(
                        text: Binding(
                            get: { viewModel.selectedPersonaPrompt },
                            set: { viewModel.selectedPersonaPrompt = $0 }
                        )
                    )
                    .font(.studioMono(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: StudioTheme.Layout.textEditorMinHeight)
                    .padding(StudioTheme.Insets.textEditor)
                    .background(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                            .fill(StudioTheme.surfaceMuted)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                            .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
                    )

                    HStack {
                        Text("Persona rewrite is \(viewModel.personaRewriteEnabled ? "enabled" : "disabled").")
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        StudioButton(title: "Delete", systemImage: nil, variant: .ghost) {
                            viewModel.deleteSelectedPersona()
                        }
                        StudioButton(title: "Set Active", systemImage: nil, variant: .primary) {
                            viewModel.activateSelectedPersona()
                        }
                    }
                }
            }
        }
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: "Keep local history",
                        subtitle: "Recent dictation sessions stay on this device unless you export them."
                    ) {
                        StudioButton(title: "Refresh", systemImage: "arrow.clockwise", variant: .secondary) {
                            viewModel.refreshHistory()
                        }
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: "Export archive",
                        subtitle: "Download your history as markdown or clear the current timeline."
                    ) {
                        HStack(spacing: StudioTheme.Spacing.medium) {
                            StudioButton(title: "Export Markdown", systemImage: "square.and.arrow.up", variant: .primary) {
                                viewModel.exportHistory()
                            }
                            StudioButton(title: "Clear", systemImage: "trash", variant: .ghost) {
                                viewModel.clearHistory()
                            }
                        }
                    }
                }
            }

            sessionStream(records: viewModel.displayedHistory)
        }
    }

    private var debugPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            HStack(spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    StudioSectionTitle(title: "Runtime Status")
                    debugLine(title: "STT Provider", value: viewModel.sttProvider.displayName)
                    debugLine(title: "LLM Provider", value: viewModel.llmProvider.displayName)
                    debugLine(title: "Ollama", value: viewModel.ollamaStatus)
                }

                StudioCard {
                    StudioSectionTitle(title: "Quick Actions")
                    StudioButton(title: "Prepare Local Model", systemImage: "arrow.down.circle", variant: .primary) {
                        viewModel.prepareOllamaModel()
                    }
                    StudioButton(title: "Open Models", systemImage: "cpu", variant: .secondary) {
                        viewModel.navigate(to: .models)
                    }
                }
                .frame(width: StudioTheme.Layout.debugActionsCardWidth)
            }

            StudioCard {
                HStack {
                    Text("Recent Errors")
                        .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer()
                    StudioButton(title: "Clear", systemImage: nil, variant: .ghost) {
                        viewModel.errorLogStore.clear()
                    }
                }

                if viewModel.errorLogStore.entries.isEmpty {
                    Text("No errors recorded.")
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.vertical, StudioTheme.Insets.errorEmptyVertical)
                } else {
                    VStack(spacing: StudioTheme.Spacing.none) {
                        ForEach(viewModel.errorLogStore.entries) { entry in
                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                                Text(entry.date, style: .time)
                                    .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                Text(entry.message)
                                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                                    .foregroundStyle(StudioTheme.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, StudioTheme.Insets.historyRowVertical)

                            if entry.id != viewModel.errorLogStore.entries.last?.id {
                                Divider().overlay(StudioTheme.border)
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSectionTitle(title: "General Behaviour")

            StudioCard {
                StudioSettingRow(
                    title: "Enable Press-and-Hold Hotkey",
                    subtitle: "Keep the recorder ready from the menu bar with your debug override hotkey."
                ) {
                    Toggle("", isOn: Binding(get: { viewModel.enableFn }, set: viewModel.setEnableFn))
                        .toggleStyle(.switch)
                }

                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                StudioSettingRow(
                    title: "Use Apple Speech as Fallback",
                    subtitle: "Drop back to the local system recognizer when Whisper is unavailable."
                ) {
                    Toggle("", isOn: Binding(get: { viewModel.appleSpeechFallback }, set: viewModel.setAppleSpeechFallback))
                        .toggleStyle(.switch)
                }
            }

            StudioSectionTitle(title: "Identity & Interaction")

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    Text("Default Persona")
                        .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("Select the voice identity used for new dictation sessions.")
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)

                    Picker(
                        "",
                        selection: Binding(
                            get: { viewModel.selectedPersonaID },
                            set: viewModel.selectPersona
                        )
                    ) {
                        ForEach(viewModel.personas) { persona in
                            Text(persona.name).tag(Optional(persona.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    StudioButton(title: "Open Personas", systemImage: nil, variant: .ghost) {
                        viewModel.navigate(to: .personas)
                    }
                }
                .frame(maxWidth: .infinity)

                StudioCard {
                    Text("Activation Hotkey")
                        .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("The keyboard shortcut used to trigger voice recording.")
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)

                    if let first = viewModel.customHotkeys.first {
                        Text(HotkeyFormat.display(first))
                            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
                            .padding(.vertical, StudioTheme.Insets.buttonVertical)
                            .background(
                                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                                    .fill(StudioTheme.surfaceMuted)
                            )
                    } else {
                        Text("Option + Space")
                            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
                            .padding(.vertical, StudioTheme.Insets.buttonVertical)
                            .background(
                                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                                    .fill(StudioTheme.surfaceMuted)
                            )
                    }

                    Button(recorder.isRecording ? "Recording…" : "Record New") {
                        if recorder.isRecording {
                            recorder.stop()
                        } else {
                            recorder.start { binding in
                                viewModel.addHotkey(binding)
                            }
                        }
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                    .foregroundStyle(StudioTheme.accent)
                }
                .frame(maxWidth: .infinity)
            }

            StudioCard {
                HStack {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                        .fill(StudioTheme.accentSoft)
                        .frame(width: StudioTheme.ControlSize.appearanceBadge, height: StudioTheme.ControlSize.appearanceBadge)
                        .overlay(
                            Image(systemName: "paintbrush.pointed.fill")
                                .foregroundStyle(StudioTheme.accent)
                        )

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                        Text("Appearance")
                            .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text("Switch the component system between light, dark, or system-following themes.")
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }

                    Spacer()

                    Picker(
                        "",
                        selection: Binding(
                            get: { viewModel.appearanceMode },
                            set: viewModel.setAppearanceMode
                        )
                    ) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: StudioTheme.Layout.appearancePickerWidth)
                }
            }
        }
    }

    private var parameterCard: some View {
        StudioCard {
            StudioSectionTitle(title: "Configuration")
            if viewModel.modelDomain == .stt {
                StudioTextInputCard(label: "Whisper Base URL", placeholder: "https://api.openai.com/v1", text: Binding(get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL))
                StudioTextInputCard(label: "Whisper Model", placeholder: "whisper-1", text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel))
                Toggle("Enable Apple fallback", isOn: Binding(get: { viewModel.appleSpeechFallback }, set: viewModel.setAppleSpeechFallback))
                    .toggleStyle(.switch)
            } else {
                if viewModel.llmProvider == .ollama {
                    StudioTextInputCard(label: "Ollama Base URL", placeholder: "http://127.0.0.1:11434", text: Binding(get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL))
                    StudioTextInputCard(label: "Local Model", placeholder: "qwen2.5:7b", text: Binding(get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel))
                    Toggle("Automatic local setup", isOn: Binding(get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup))
                        .toggleStyle(.switch)
                } else {
                    StudioTextInputCard(label: "Remote Base URL", placeholder: "https://api.openai.com/v1", text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL))
                    StudioTextInputCard(label: "Model", placeholder: "gpt-4o-mini", text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel))
                    StudioTextInputCard(label: "API Key", placeholder: "sk-...", text: Binding(get: { viewModel.llmAPIKey }, set: viewModel.setLLMAPIKey), secure: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionCard: some View {
        StudioCard {
            StudioSectionTitle(title: "Activation")
            Text("Custom Architecture?")
                .font(.studioDisplay(StudioTheme.Typography.settingTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text("Import your own gateway URL or prepare a local model directly from the component-driven configuration panels.")
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)

            Spacer(minLength: StudioTheme.Spacing.smallMedium)

            HStack {
                StudioPill(title: "CoreML")
                StudioPill(title: "ONNX")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.actionCardMinHeight)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudioTheme.accentSoft,
                            StudioTheme.Colors.actionCardWarm,
                            StudioTheme.Colors.actionCardCool
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
    }

    private func historyTable(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            VStack(spacing: StudioTheme.Spacing.none) {
                HStack {
                    Text("Timestamp")
                        .frame(width: StudioTheme.Layout.historyTimestampColumnWidth, alignment: .leading)
                    Text("Source File")
                        .frame(width: StudioTheme.Layout.historySourceColumnWidth, alignment: .leading)
                    Text("Recognized Text")
                    Spacer()
                }
                .font(.studioBody(StudioTheme.Typography.sidebarEyebrow, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, StudioTheme.Insets.historyHeaderHorizontal)
                .padding(.top, StudioTheme.Insets.historyHeaderTop)
                .padding(.bottom, StudioTheme.Insets.historyHeaderBottom)

                Divider().overlay(StudioTheme.border)

                if records.isEmpty {
                    Text("No history entries yet.")
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, StudioTheme.Insets.historyEmptyVertical)
                } else {
                    ForEach(records) { record in
                        StudioHistoryRow(record: record)
                        if record.id != records.last?.id {
                            Divider().overlay(StudioTheme.border)
                        }
                    }
                }
            }
        }
    }

    private var overviewPanel: some View {
        StudioCard(padding: StudioTheme.Insets.cardCompact) {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                StudioCard(padding: StudioTheme.Insets.cardDense) {
                    HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                            HStack(spacing: StudioTheme.Spacing.small) {
                                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                    .fill(StudioTheme.surfaceMuted)
                                    .frame(width: StudioTheme.ControlSize.overviewBadge, height: StudioTheme.ControlSize.overviewBadge)
                                    .overlay(
                                        Image(systemName: "waveform.and.magnifyingglass")
                                            .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                                            .foregroundStyle(StudioTheme.textSecondary)
                                    )
                                Text("Overall activity")
                                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }

                            Text("\(completionRate)%")
                                .font(.studioDisplay(StudioTheme.Typography.displayLarge, weight: .bold))
                                .foregroundStyle(StudioTheme.textPrimary)

                            Text("Completion rate")
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)

                            StudioButton(title: "View report", systemImage: nil, variant: .secondary) {
                                viewModel.navigate(to: .history)
                            }

                            Spacer(minLength: StudioTheme.Spacing.smallMedium)

                            Text("Your voice data stays on-device unless you export it.")
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.textTertiary)
                                .frame(maxWidth: 240, alignment: .leading)
                        }

                        Spacer(minLength: StudioTheme.Spacing.medium)

                        Circle()
                            .stroke(StudioTheme.surfaceMuted, lineWidth: StudioTheme.BorderWidth.overviewDonut)
                            .frame(width: StudioTheme.Layout.overviewDonutSize, height: StudioTheme.Layout.overviewDonutSize)
                            .overlay(
                                Circle()
                                    .trim(from: 0, to: CGFloat(completionRate) / 100)
                                    .stroke(StudioTheme.accent.opacity(StudioTheme.Opacity.overviewProgress), style: StrokeStyle(lineWidth: StudioTheme.BorderWidth.overviewDonut, lineCap: .round))
                                    .rotationEffect(.degrees(StudioTheme.Angles.overviewProgressStart))
                            )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.overviewPrimaryMinHeight)
                .background(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.overviewActivityFill))
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                        GridItem(.flexible(), spacing: StudioTheme.Spacing.medium)
                    ],
                    alignment: .leading,
                    spacing: StudioTheme.Spacing.medium
                ) {
                    homeMiniMetric(icon: "clock", value: "\(viewModel.transcriptionMinutesText) min", title: "Total dictation time")
                    homeMiniMetric(icon: "mic", value: "\(characterCount)", title: "Characters dictated")
                    homeMiniMetric(icon: "hourglass", value: "\(savedMinutes) min", title: "Time saved")
                    homeMiniMetric(icon: "bolt", value: "\(wordsPerMinute)", title: "Average pace")
                }
                .frame(width: StudioTheme.Layout.overviewSideMetricsWidth)
            }
        }
        .background(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.overviewPanelFill))
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
    }

    private func homeMiniMetric(icon: String, value: String, title: String) -> some View {
        StudioCard(padding: StudioTheme.Insets.cardCompact) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.miniMetricIcon, style: .continuous)
                    .fill(StudioTheme.surfaceMuted)
                    .frame(width: StudioTheme.ControlSize.overviewMiniIcon, height: StudioTheme.ControlSize.overviewMiniIcon)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)
                    )

                Text(value)
                    .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.compactMetricMinHeight, alignment: .topLeading)
    }

    private func accentPromoCard(
        title: String,
        description: String,
        buttonTitle: String,
        colors: [Color],
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: StudioTheme.Spacing.cardCompact) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.promoIllustration, style: .continuous)
                .fill(StudioTheme.Colors.white.opacity(StudioTheme.Opacity.promoIconFill))
                .frame(width: StudioTheme.ControlSize.promoIllustration, height: StudioTheme.ControlSize.promoIllustration)
                .overlay(
                    Image(systemName: "hands.sparkles.fill")
                        .font(.system(size: StudioTheme.Typography.iconLarge, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                Text(title)
                    .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(description)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                StudioButton(title: buttonTitle, systemImage: nil, variant: .secondary, action: action)
            }
            Spacer(minLength: StudioTheme.Insets.none)
        }
        .padding(StudioTheme.Insets.promoCard)
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.promoCardMinHeight, alignment: .leading)
        .background(
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
    }

    private func sectionHeader(
        title: String,
        primaryButtonTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryButtonTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            StudioButton(title: secondaryButtonTitle, systemImage: nil, variant: .secondary, action: secondaryAction)
            StudioButton(title: primaryButtonTitle, systemImage: nil, variant: .primary, action: primaryAction)
        }
    }

    private func sessionStream(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            if records.isEmpty {
                Text("No history entries yet.")
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, StudioTheme.Insets.sessionEmptyVertical)
            } else {
                VStack(spacing: StudioTheme.Spacing.none) {
                    ForEach(records) { record in
                        StudioHistoryRow(record: record)
                        if record.id != records.last?.id {
                            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.listDivider))
                        }
                    }
                }
            }
        }
    }

    private var characterCount: Int {
        viewModel.historyRecords.reduce(0) { $0 + $1.text.count }
    }

    private var savedMinutes: Int {
        max(1, Int(round(Double(characterCount) / 160.0)))
    }

    private var wordsPerMinute: String {
        let minutes = max(1, totalProcessedMinutes)
        return "\(max(80, characterCount / minutes)) wpm"
    }

    private var completionRate: Int {
        let count = max(viewModel.historyRecords.count, 1)
        return min(98, max(12, 42 + count * 3))
    }

    private var totalProcessedMinutes: Int {
        viewModel.historyRecords.count * 3 + viewModel.historyRecords.reduce(0) { $0 + min($1.text.count / 80, 12) }
    }

    private func modelCard(_ card: StudioModelCard) -> some View {
        StudioCard {
            HStack {
                StudioPill(title: card.badge)
                Spacer()
                if card.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: StudioTheme.Typography.iconMedium, weight: .bold))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }

            Text(card.name)
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                .foregroundStyle(card.isMuted ? StudioTheme.textSecondary : StudioTheme.textPrimary)
            Text(card.summary)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: StudioTheme.Spacing.xSmall)

            HStack {
                Text(card.metadata)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                StudioButton(title: card.actionTitle, systemImage: nil, variant: card.isSelected ? .secondary : .primary) {
                    handleModelSelection(card)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.modelCardMinHeight)
        .opacity(card.isMuted ? StudioTheme.Opacity.modelCardMuted : 1)
    }

    private var isLocalArchitecture: Bool {
        switch viewModel.modelDomain {
        case .stt:
            return viewModel.sttProvider == .appleSpeech
        case .llm:
            return viewModel.llmProvider == .ollama
        }
    }

    private func architectureModeButton(title: String, subtitle: String, isActive: Bool) -> some View {
        HStack(spacing: StudioTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(isActive ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                .frame(width: StudioTheme.ControlSize.architectureBadge, height: StudioTheme.ControlSize.architectureBadge)
                .overlay(
                    Image(systemName: title.contains("Local") ? "cpu.fill" : "cloud.fill")
                        .foregroundStyle(isActive ? StudioTheme.accent : StudioTheme.textSecondary)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            Circle()
                .stroke(isActive ? StudioTheme.accent : StudioTheme.border, lineWidth: StudioTheme.BorderWidth.emphasis)
                .frame(width: StudioTheme.ControlSize.selectionIndicator, height: StudioTheme.ControlSize.selectionIndicator)
                .overlay(
                    Circle()
                        .fill(isActive ? StudioTheme.accent : Color.clear)
                        .frame(width: StudioTheme.ControlSize.selectionIndicatorInner, height: StudioTheme.ControlSize.selectionIndicatorInner)
                )
            }
        .padding(StudioTheme.Insets.cardCompact)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.architectureOption, style: .continuous)
                .fill(isActive ? StudioTheme.surface : StudioTheme.surfaceMuted)
        )
    }

    private func handleModelSelection(_ card: StudioModelCard) {
        switch card.id {
        case "apple-speech":
            viewModel.setSTTModelSelection(.appleSpeech, suggestedModel: viewModel.whisperModel)
        case "whisper-api":
            viewModel.setSTTModelSelection(.whisperAPI, suggestedModel: viewModel.whisperModel.isEmpty ? "whisper-1" : viewModel.whisperModel)
        case "ollama-local":
            viewModel.setLLMModelSelection(.ollama, suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel)
        case "openai-compatible":
            viewModel.setLLMModelSelection(.openAICompatible, suggestedModel: viewModel.llmModel.isEmpty ? "gpt-4o-mini" : viewModel.llmModel)
        default:
            break
        }
    }

    private func debugLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            Text(value)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
