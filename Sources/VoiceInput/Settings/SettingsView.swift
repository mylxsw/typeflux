import SwiftUI

private enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .automatic:
            return "Auto-added"
        case .manual:
            return "Manually-added"
        }
    }

    var source: VocabularySource? {
        switch self {
        case .all:
            return nil
        case .automatic:
            return .automatic
        case .manual:
            return .manual
        }
    }

    var iconName: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .automatic:
            return "sparkles"
        case .manual:
            return "hand.draw"
        }
    }
}

struct StudioView: View {
    private enum ShortcutRecordingTarget {
        case activation
        case persona
    }

    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingTarget: ShortcutRecordingTarget?
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var isAddingVocabulary = false
    @State private var newVocabularyTerm = ""
    @State private var personaPendingDeletion: PersonaProfile?

    var body: some View {
        StudioShell(
            currentSection: viewModel.currentSection,
            onSelect: viewModel.navigate,
            onOpenAbout: { AboutWindowController.shared.show() },
            searchText: $viewModel.searchQuery,
            searchPlaceholder: viewModel.currentSection.searchPlaceholder
        ) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.heroSection) {
                pageHeader

                currentPage
            }
            .id(viewModel.currentSection)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: viewModel.currentSection)
        }
        .onAppear {
            viewModel.schedulePermissionRefresh()
        }
        .preferredColorScheme(viewModel.preferredColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.schedulePermissionRefresh()
        }
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
        .sheet(isPresented: $isAddingVocabulary) {
            vocabularyAddSheet
        }
        .confirmationDialog(
            "Delete Persona?",
            isPresented: Binding(
                get: { personaPendingDeletion != nil },
                set: { if !$0 { personaPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let personaPendingDeletion else { return }
                viewModel.deletePersona(id: personaPendingDeletion.id)
                self.personaPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                personaPendingDeletion = nil
            }
        } message: {
            if let personaPendingDeletion {
                Text("Delete \"\(personaPendingDeletion.name)\"? This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private var pageHeader: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
            StudioHeroHeader(
                eyebrow: viewModel.currentSection.eyebrow,
                title: viewModel.currentSection.heading,
                subtitle: viewModel.currentSection.subheading
            )

            if viewModel.currentSection == .history {
                Spacer()

                StudioButton(
                    title: viewModel.isRefreshingHistory ? "Refreshing..." : "Refresh",
                    systemImage: "arrow.clockwise",
                    variant: .secondary,
                    isLoading: viewModel.isRefreshingHistory
                ) {
                    viewModel.refreshHistoryWithFeedback()
                }
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
        case .vocabulary:
            vocabularyPage
        case .history:
            historyPage
        case .settings:
            settingsPage
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            overviewPanel

            sectionHeader(
                title: "Recent Transcriptions",
                secondaryButtonTitle: "Export All",
                secondaryAction: { viewModel.exportHistory() },
                primaryButtonTitle: "Open History",
                primaryAction: { viewModel.navigate(to: .history) }
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

            HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                    LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                        ForEach(modelProviderCards) { card in
                            modelProviderSelectionCard(card)
                        }
                    }
                }
                .frame(width: StudioTheme.Layout.modelProviderListWidth, alignment: .leading)

                focusedProviderConfigurationPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func modelDomainTabTitle(for domain: StudioModelDomain) -> String {
        switch domain {
        case .stt:
            return "Speech Provider"
        case .llm:
            return "LLM Providers"
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
                    Button(action: viewModel.beginCreatingPersona) {
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
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                viewModel.selectPersona(persona.id)
                                personaPendingDeletion = persona
                            }
                        }
                    }
                }
            }
            .frame(width: StudioTheme.Layout.personasListWidth)

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioTextInputCard(
                        label: "Persona Name",
                        placeholder: "Enter persona name",
                        text: Binding(
                            get: { viewModel.personaDraftName },
                            set: { viewModel.personaDraftName = $0 }
                        )
                    )
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSectionTitle(title: "System Prompt")

                    TextEditor(
                        text: Binding(
                            get: { viewModel.personaDraftPrompt },
                            set: { viewModel.personaDraftPrompt = $0 }
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
                }

                HStack {
                    Spacer()
                    StudioButton(title: "Cancel", systemImage: nil, variant: .secondary) {
                        viewModel.cancelPersonaEditing()
                    }
                    StudioButton(
                        title: "Save",
                        systemImage: nil,
                        variant: .primary,
                        isDisabled: !viewModel.canSavePersonaDraft || !viewModel.hasPersonaDraftChanges
                    ) {
                        viewModel.savePersonaDraft()
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
                        title: "Keep history",
                        subtitle: "Choose how long VoiceInput keeps local dictation history on this device."
                    ) {
                        StudioMenuPicker(
                            options: HistoryRetentionPolicy.allCases.map { (label: $0.title, value: $0) },
                            selection: Binding(
                                get: { viewModel.historyRetentionPolicy },
                                set: viewModel.setHistoryRetentionPolicy
                            ),
                            width: 140
                        )
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: "Your data stays private",
                        subtitle: "Voice dictation history is only stored on this Mac. Auto-cleanup removes expired local entries and linked audio files."
                    ) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(StudioTheme.textSecondary)
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

            groupedSessionStream(sections: viewModel.groupedHistory)
        }
    }

    private func groupedSessionStream(sections: [HistorySection]) -> some View {
        LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if sections.isEmpty {
                StudioCard(padding: StudioTheme.Insets.none) {
                    Text("No history entries yet.")
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, StudioTheme.Insets.sessionEmptyVertical)
                }
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                        Text(section.id)
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, StudioTheme.Insets.historyRowHorizontal)

                        StudioCard(padding: StudioTheme.Insets.none) {
                            VStack(spacing: StudioTheme.Spacing.none) {
                                ForEach(section.records) { record in
                                    StudioHistoryRow(
                                        record: record,
                                        onCopyTranscript: {
                                            viewModel.copyTranscript(id: record.id)
                                        },
                                        onDownloadAudio: {
                                            viewModel.downloadAudio(id: record.id)
                                        },
                                        onDelete: {
                                            viewModel.deleteHistoryRecord(id: record.id)
                                        },
                                        onRetry: {
                                            viewModel.retryHistoryRecord(id: record.id)
                                        }
                                    )
                                    if record.id != section.records.last?.id {
                                        Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.listDivider))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if viewModel.isLoadingMoreHistory {
                HStack(spacing: StudioTheme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more history...")
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, StudioTheme.Spacing.medium)
            } else if viewModel.canLoadMoreHistory {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        viewModel.loadMoreHistoryIfNeeded()
                    }
            }
        }
    }

    private var vocabularyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                    Text("Help VoiceInput catch names, products, and domain terms more reliably.")
                        .font(.studioBody(StudioTheme.Typography.bodyLarge))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Text("Manual entries are sent as recognition hints to Whisper-compatible transcription backends.")
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textTertiary)
                }

                Spacer()

                StudioButton(title: "New word", systemImage: "plus", variant: .primary) {
                    newVocabularyTerm = ""
                    isAddingVocabulary = true
                }
            }

            StudioCard {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        ForEach(VocabularyFilter.allCases) { filter in
                            vocabularyFilterChip(filter)
                        }
                    }

                    Spacer()

                    HStack(spacing: StudioTheme.Spacing.small) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(StudioTheme.textTertiary)

                        TextField("Search vocabulary...", text: $viewModel.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .frame(width: 220)
                    }
                    .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
                    .padding(.vertical, StudioTheme.Insets.textFieldVertical)
                    .background(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                            .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                            .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
                    )
                }

                if filteredVocabularyEntries.isEmpty {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        Text("No vocabulary terms yet.")
                            .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text("Add product names, people, brands, or jargon you use frequently to improve recognition quality.")
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                        StudioButton(title: "Add your first word", systemImage: "plus", variant: .secondary) {
                            newVocabularyTerm = ""
                            isAddingVocabulary = true
                        }
                    }
                    .padding(.vertical, StudioTheme.Insets.historyEmptyVertical)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                            GridItem(.flexible(), spacing: StudioTheme.Spacing.medium)
                        ],
                        alignment: .leading,
                        spacing: StudioTheme.Spacing.medium
                    ) {
                        ForEach(filteredVocabularyEntries) { entry in
                            vocabularyTermCard(entry)
                        }
                    }
                }
            }

        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSectionTitle(title: "General")

            StudioCard {
                StudioSettingRow(
                    title: "开机自动启动",
                    subtitle: "登录 Mac 后自动启动 VoiceInput，无需手动打开。"
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { viewModel.launchAtLogin },
                            set: viewModel.setLaunchAtLogin
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            StudioSectionTitle(title: "Activation Hotkey")

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                        shortcutConfigurationRow(
                            title: "Primary trigger",
                            subtitle: "Use one shortcut to start dictation. Hold to talk, or tap quickly to lock the recording session.",
                            footnote: "Default is Right Command. You can replace it with any modifier-based combination and reset it later.",
                            icon: "command",
                            badgeSymbol: "mic.fill",
                            binding: viewModel.activationHotkey,
                            isDefault: viewModel.activationHotkey.signature == HotkeyBinding.defaultActivation.signature,
                            onStartRecording: {
                                recordingTarget = .activation
                                recorder.start { binding in
                                    viewModel.setActivationHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetActivationHotkey()
                            }
                        )

                        Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                        shortcutConfigurationRow(
                            title: "Persona switcher",
                            subtitle: "Open a centered picker, move with Up and Down, then press Return to switch the active persona instantly.",
                            footnote: "The picker includes No Persona and every saved persona, so you can switch styles without opening Settings.",
                            icon: "person.crop.rectangle.stack.fill",
                            badgeSymbol: "person.crop.circle.badge.checkmark",
                            binding: viewModel.personaHotkey,
                            isDefault: viewModel.personaHotkey.signature == HotkeyBinding.defaultPersona.signature,
                            onStartRecording: {
                                recordingTarget = .persona
                                recorder.start { binding in
                                    viewModel.setPersonaHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetPersonaHotkey()
                            }
                        )
                    }

                    if recorder.isRecording {
                        recordingShortcutBanner
                    }
                }
            }

            StudioSectionTitle(title: "Identity & Interaction")

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                                .fill(StudioTheme.accentSoft)
                                .frame(width: 46, height: 46)
                                .overlay(
                                    Image(systemName: "person.crop.rectangle.stack.fill")
                                        .foregroundStyle(StudioTheme.accent)
                                )

                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                                Text("Default Persona")
                                    .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                Text("Choose the writing identity that should shape new dictation sessions.")
                                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }

                            Spacer()

                            if let selectedID = viewModel.defaultPersonaSelectionID,
                               let persona = viewModel.personas.first(where: { $0.id == selectedID }) {
                                StudioPill(title: persona.name)
                            } else {
                                StudioPill(title: "No Persona", systemImage: "person.slash")
                            }
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium)
                            ],
                            alignment: .leading,
                            spacing: StudioTheme.Spacing.medium
                        ) {
                            personaSelectionCard(
                                title: "No Persona",
                                subtitle: "Dictate without any persona styling.",
                                initials: "",
                                systemImage: "person.slash.fill",
                                isSelected: viewModel.defaultPersonaSelectionID == nil
                            ) {
                                viewModel.setDefaultPersonaSelection(nil)
                            }

                            ForEach(viewModel.personas) { persona in
                                personaSelectionCard(
                                    title: persona.name,
                                    subtitle: persona.prompt,
                                    initials: String(persona.name.prefix(2)).uppercased(),
                                    isSelected: viewModel.defaultPersonaSelectionID == persona.id
                                ) {
                                    viewModel.setDefaultPersonaSelection(persona.id)
                                }
                            }
                        }

                        HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                            Text(
                                viewModel.personaRewriteEnabled
                                    ? "New dictation sessions will be rewritten with the selected persona."
                                    : "Persona is currently off, so dictation will stay in its plain form."
                            )
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)

                            Spacer()

                            StudioButton(title: "Open Personas", systemImage: nil, variant: .secondary) {
                                viewModel.navigate(to: .personas)
                            }
                        }
                    }
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

                    StudioSegmentedPicker(
                        options: AppearanceMode.allCases.map { (label: $0.displayName, value: $0) },
                        selection: Binding(
                            get: { viewModel.appearanceMode },
                            set: viewModel.setAppearanceMode
                        )
                    )
                    .frame(width: StudioTheme.Layout.appearancePickerWidth)
                }
            }

            StudioSectionTitle(title: "Audio")

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: "Microphone",
                        subtitle: "Pick the device used for dictation. Automatic follows the current macOS default input."
                    ) {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            StudioMenuPicker(
                                options: [(label: "Automatic", value: AudioDeviceManager.automaticDeviceID)] +
                                         viewModel.availableMicrophones.map { (label: $0.name, value: $0.id) },
                                selection: Binding(
                                    get: { viewModel.preferredMicrophoneID },
                                    set: viewModel.setPreferredMicrophoneID
                                ),
                                width: 260
                            )

                            StudioButton(title: "Refresh", systemImage: "arrow.clockwise", variant: .secondary) {
                                viewModel.refreshAvailableMicrophones()
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: "Mute During Recording",
                        subtitle: "Temporarily mute the system output while recording to reduce feedback or system sounds leaking into the microphone."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.muteSystemOutputDuringRecording },
                                set: viewModel.setMuteSystemOutputDuringRecording
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            StudioSectionTitle(title: "Permissions")

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: "Permission Status",
                        subtitle: "Review the macOS permissions VoiceInput depends on, then grant access where needed."
                    ) {
                        StudioButton(
                            title: viewModel.isRefreshingPermissions ? "Refreshing..." : "Refresh",
                            systemImage: "arrow.clockwise",
                            variant: .secondary,
                            isLoading: viewModel.isRefreshingPermissions
                        ) {
                            viewModel.refreshPermissionRowsWithFeedback()
                        }
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                        ForEach(viewModel.permissionRows) { permission in
                            permissionRow(permission)

                            if permission.id != viewModel.permissionRows.last?.id {
                                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                            }
                        }
                    }
                }
            }
        }
    }

    private func shortcutConfigurationRow(
        title: String,
        subtitle: String,
        footnote: String,
        icon: String,
        badgeSymbol: String,
        binding: HotkeyBinding,
        isDefault: Bool,
        onStartRecording: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [StudioTheme.accentSoft, StudioTheme.surfaceMuted],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(title)
                    .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(footnote)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)

            Spacer(minLength: StudioTheme.Spacing.large)

            shortcutPill(binding, accentSymbol: badgeSymbol)
                .frame(minWidth: 170, alignment: .leading)

            shortcutActionButtons(
                isDefault: isDefault,
                onStart: onStartRecording,
                onReset: onReset
            )
        }
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private var recordingShortcutBanner: some View {
        HStack(spacing: StudioTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(StudioTheme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "keyboard")
                        .foregroundStyle(StudioTheme.accent)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text("Recording a new shortcut")
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(recordingBannerDescription)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            Spacer()
        }
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.accentSoft.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.accent.opacity(0.28), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private func shortcutKeycap(_ title: String) -> some View {
        Text(title)
            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .fill(StudioTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .stroke(StudioTheme.border.opacity(0.75), lineWidth: StudioTheme.BorderWidth.thin)
            )
    }

    private var recordingBannerDescription: String {
        switch recordingTarget {
        case .activation:
            return "Press the new activation combination now. Include at least one modifier key."
        case .persona:
            return "Press the shortcut that should open the persona picker. Include at least one modifier key."
        case nil:
            return "Press the full key combination you want to use. Include at least one modifier key."
        }
    }

    private func shortcutActionButtons(
        isDefault: Bool,
        onStart: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            StudioButton(
                title: recorder.isRecording ? "Stop Recording" : "Record",
                systemImage: recorder.isRecording ? "stop.circle.fill" : "keyboard",
                variant: recorder.isRecording ? .secondary : .primary
            ) {
                if recorder.isRecording {
                    recorder.stop()
                    recordingTarget = nil
                } else {
                    onStart()
                }
            }

            StudioButton(title: "Reset", systemImage: "arrow.counterclockwise", variant: .secondary, isDisabled: isDefault) {
                onReset()
            }
        }
    }

    private func shortcutPill(_ binding: HotkeyBinding, accentSymbol: String) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: accentSymbol)
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)

            Text(HotkeyFormat.display(binding))
                .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private func personaSelectionCard(
        title: String,
        subtitle: String,
        initials: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                        .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                        .frame(width: 42, height: 42)
                        .overlay(
                            Group {
                                if let systemImage {
                                    Image(systemName: systemImage)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                                } else {
                                    Text(initials)
                                        .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                                }
                            }
                        )

                    Spacer()

                    Circle()
                        .stroke(isSelected ? StudioTheme.accent : StudioTheme.border, lineWidth: StudioTheme.BorderWidth.emphasis)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .fill(isSelected ? StudioTheme.accent : Color.clear)
                                .frame(width: 8, height: 8)
                        )
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(StudioTheme.Insets.cardCompact)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft.opacity(0.75) : StudioTheme.surfaceMuted.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.45) : StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: isSelected ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func permissionRow(_ permission: StudioPermissionRowModel) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                HStack(spacing: StudioTheme.Spacing.small) {
                    Image(systemName: permission.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(permission.isGranted ? StudioTheme.success : StudioTheme.warning)

                    Text(permission.title)
                        .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    StudioPill(
                        title: permission.badgeText,
                        tone: permission.isGranted ? StudioTheme.success : StudioTheme.warning,
                        fill: (permission.isGranted ? StudioTheme.success : StudioTheme.warning).opacity(0.12)
                    )
                }

                Text(permission.summary)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textSecondary)

                Text(permission.detail)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
            }

            Spacer(minLength: StudioTheme.Spacing.pageGroup)

            StudioButton(
                title: permission.actionTitle,
                systemImage: permission.isGranted ? "arrow.up.right.square" : "lock.open.display",
                variant: permission.isGranted ? .secondary : .primary
            ) {
                viewModel.requestPermission(permission.id)
            }
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
    }

    private var filteredVocabularyEntries: [VocabularyEntry] {
        let entries = viewModel.filteredVocabularyEntries
        guard let source = vocabularyFilter.source else { return entries }
        return entries.filter { $0.source == source }
    }

    private func vocabularyFilterChip(_ filter: VocabularyFilter) -> some View {
        Button {
            vocabularyFilter = filter
        } label: {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: filter.iconName)
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                Text(filter.title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                Text("\(vocabularyCount(for: filter))")
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                    .foregroundStyle(vocabularyFilter == filter ? StudioTheme.textPrimary : StudioTheme.textTertiary)
            }
            .foregroundStyle(vocabularyFilter == filter ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical + 2)
            .background(
                Capsule()
                    .fill(vocabularyFilter == filter ? StudioTheme.surface : StudioTheme.surfaceMuted.opacity(0.82))
            )
            .overlay(
                Capsule()
                    .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func vocabularyTermCard(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: entry.source == .automatic ? "sparkles" : "plus.circle.fill")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                .foregroundStyle(entry.source == .automatic ? StudioTheme.warning : StudioTheme.accent)

            Text(entry.term)
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            Button {
                viewModel.removeVocabularyEntry(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .bold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(StudioTheme.surfaceMuted.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, StudioTheme.Insets.cardCompact)
        .padding(.vertical, StudioTheme.Insets.buttonVertical)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private var vocabularyAddSheet: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            Text("Add to vocabulary")
                .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text("Use one term per entry. This works best for names, brands, product terms, and other frequently dictated jargon.")
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)

            TextField("Add a new word", text: $newVocabularyTerm)
                .textFieldStyle(.plain)
                .font(.studioBody(StudioTheme.Typography.bodyLarge))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
                .padding(.vertical, StudioTheme.Insets.textFieldVertical)
                .background(
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                        .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                        .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
                )
                .onSubmit {
                    submitVocabularyTerm()
                }

            HStack {
                Spacer()
                StudioButton(title: "Cancel", systemImage: nil, variant: .secondary) {
                    isAddingVocabulary = false
                }
                StudioButton(
                    title: "Add word",
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    submitVocabularyTerm()
                }
            }
        }
        .padding(32)
        .frame(width: 520)
    }

    private func submitVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        viewModel.addVocabularyTerm(term)
        newVocabularyTerm = ""
        isAddingVocabulary = false
    }

    private func vocabularyCount(for filter: VocabularyFilter) -> Int {
        guard let source = filter.source else { return viewModel.vocabularyEntries.count }
        return viewModel.vocabularyEntries.filter { $0.source == source }.count
    }

    private func uniqueSuggestions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private var whisperEndpointSuggestions: [String] {
        OpenAIAudioModelCatalog.whisperEndpoints
    }

    private var whisperModelSuggestions: [String] {
        OpenAIAudioModelCatalog.whisperModels
    }

    private var llmEndpointSuggestions: [String] {
        uniqueSuggestions([
            viewModel.llmBaseURL,
            viewModel.whisperBaseURL,
            viewModel.multimodalLLMBaseURL,
            "https://api.openai.com/v1",
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "http://127.0.0.1:11434/v1"
        ])
    }

    private var llmModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.llmModel,
            "gpt-4o-mini",
            "gpt-4.1-mini",
            "gpt-4.1"
        ])
    }

    private var ollamaEndpointSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaBaseURL,
            "http://127.0.0.1:11434",
            "http://localhost:11434"
        ])
    }

    private var ollamaModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaModel,
            "qwen2.5:7b",
            "llama3.2:3b",
            "gemma3:4b"
        ])
    }

    private var multimodalEndpointSuggestions: [String] {
        OpenAIAudioModelCatalog.multimodalEndpoints
    }

    private var multimodalModelSuggestions: [String] {
        OpenAIAudioModelCatalog.multimodalModels
    }

    private var parameterCard: some View {
        StudioCard {
            StudioSectionTitle(title: "Configuration")
            if viewModel.modelDomain == .stt {
                StudioSuggestedTextInputCard(
                    label: "Whisper Endpoint",
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: Binding(get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL),
                    suggestions: whisperEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: "Whisper Model",
                    placeholder: OpenAIAudioModelCatalog.whisperModels[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions
                )
                Toggle("Enable Apple fallback", isOn: Binding(get: { viewModel.appleSpeechFallback }, set: viewModel.setAppleSpeechFallback))
                    .toggleStyle(.switch)
            } else {
                if viewModel.llmProvider == .ollama {
                    StudioSuggestedTextInputCard(
                        label: "Ollama Base URL",
                        placeholder: "http://127.0.0.1:11434",
                        text: Binding(get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL),
                        suggestions: ollamaEndpointSuggestions
                    )
                    StudioSuggestedTextInputCard(
                        label: "Local Model",
                        placeholder: "qwen2.5:7b",
                        text: Binding(get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel),
                        suggestions: ollamaModelSuggestions
                    )
                    Toggle("Automatic local setup", isOn: Binding(get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup))
                        .toggleStyle(.switch)
                } else {
                    StudioSuggestedTextInputCard(
                        label: "Remote Base URL",
                        placeholder: "https://api.openai.com/v1",
                        text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                        suggestions: llmEndpointSuggestions
                    )
                    StudioSuggestedTextInputCard(
                        label: "Model",
                        placeholder: "gpt-4o-mini",
                        text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                        suggestions: llmModelSuggestions
                    )
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
                        StudioHistoryRow(
                            record: record,
                            onCopyTranscript: {
                                viewModel.copyTranscript(id: record.id)
                            },
                            onDownloadAudio: {
                                viewModel.downloadAudio(id: record.id)
                            },
                            onDelete: {
                                viewModel.deleteHistoryRecord(id: record.id)
                            },
                            onRetry: {
                                viewModel.retryHistoryRecord(id: record.id)
                            }
                        )
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

                            Text("\(viewModel.statsCompletionRate)%")
                                .font(.studioDisplay(StudioTheme.Typography.displayLarge, weight: .bold))
                                .foregroundStyle(StudioTheme.textPrimary)

                            Text("Completion rate")
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)

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
                                    .trim(from: 0, to: CGFloat(viewModel.statsCompletionRate) / 100)
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
                    homeMiniMetric(icon: "mic", value: "\(viewModel.statsTotalCharacters)", title: "Characters dictated")
                    homeMiniMetric(icon: "hourglass", value: "\(viewModel.statsSavedMinutes) min", title: "Time saved")
                    homeMiniMetric(icon: "bolt", value: viewModel.statsAveragePaceWPM > 0 ? "\(viewModel.statsAveragePaceWPM) wpm" : "--", title: "Average pace")
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

    private func sectionHeader(
        title: String,
        secondaryButtonTitle: String,
        secondaryAction: @escaping () -> Void,
        primaryButtonTitle: String,
        primaryAction: @escaping () -> Void
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
                        StudioHistoryRow(
                            record: record,
                            onCopyTranscript: {
                                viewModel.copyTranscript(id: record.id)
                            },
                            onDownloadAudio: {
                                viewModel.downloadAudio(id: record.id)
                            },
                            onDelete: {
                                viewModel.deleteHistoryRecord(id: record.id)
                            },
                            onRetry: {
                                viewModel.retryHistoryRecord(id: record.id)
                            }
                        )
                        if record.id != records.last?.id {
                            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.listDivider))
                        }
                    }
                }
            }
        }
    }

    private func modelCard(_ card: StudioModelCard) -> some View {
        StudioCard {
            HStack {
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
            return viewModel.sttProvider == .appleSpeech || viewModel.sttProvider == .localModel
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
        case "local-stt":
            viewModel.setSTTProvider(.localModel)
        case "whisper-api":
            viewModel.setSTTModelSelection(.whisperAPI, suggestedModel: viewModel.whisperModel.isEmpty ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel)
        case "ollama-local":
            viewModel.setLLMModelSelection(.ollama, suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel)
        case "openai-compatible":
            viewModel.setLLMModelSelection(.openAICompatible, suggestedModel: viewModel.llmModel.isEmpty ? "gpt-4o-mini" : viewModel.llmModel)
        default:
            break
        }
    }

    private var activeModelProviderID: StudioModelProviderID {
        switch viewModel.modelDomain {
        case .stt:
            switch viewModel.sttProvider {
            case .appleSpeech:
                return .appleSpeech
            case .localModel:
                return .localSTT
            case .whisperAPI:
                return .whisperAPI
            case .multimodalLLM:
                return .multimodalLLM
            case .aliCloud:
                return .aliCloud
            case .doubaoRealtime:
                return .doubaoRealtime
            }
        case .llm:
            return viewModel.llmProvider == .ollama ? .ollama : .openAICompatible
        }
    }

    private var modelProviderCards: [StudioModelCard] {
        switch viewModel.modelDomain {
        case .stt:
            return [
                StudioModelCard(
                    id: StudioModelProviderID.whisperAPI.rawValue,
                    name: "Whisper API",
                    summary: "Remote transcription through OpenAI-compatible endpoints with better model flexibility.",
                    badge: "API",
                    metadata: viewModel.whisperModel.isEmpty ? "Model not configured" : viewModel.whisperModel,
                    isSelected: viewModel.sttProvider == .whisperAPI,
                    isMuted: false,
                    actionTitle: "Use Remote"
                ),
                StudioModelCard(
                    id: StudioModelProviderID.localSTT.rawValue,
                    name: "Local Models",
                    summary: "Run Whisper, SenseVoice Small, or Qwen3-ASR locally through an embedded service runtime.",
                    badge: "Local",
                    metadata: viewModel.localSTTModel.displayName,
                    isSelected: viewModel.sttProvider == .localModel,
                    isMuted: false,
                    actionTitle: "Use Local"
                ),
                StudioModelCard(
                    id: StudioModelProviderID.multimodalLLM.rawValue,
                    name: "Multimodal LLM",
                    summary: "Send audio directly to a multimodal model. Transcription and persona rewriting happen in a single API call — faster end-to-end.",
                    badge: "API",
                    metadata: viewModel.multimodalLLMModel.isEmpty ? "Model not configured" : viewModel.multimodalLLMModel,
                    isSelected: viewModel.sttProvider == .multimodalLLM,
                    isMuted: false,
                    actionTitle: "Use Multimodal"
                ),
                StudioModelCard(
                    id: StudioModelProviderID.aliCloud.rawValue,
                    name: "Alibaba Cloud ASR",
                    summary: "Real-time streaming recognition via DashScope. Supports FunASR and Qwen3-ASR models with low-latency WebSocket streaming.",
                    badge: "API",
                    metadata: "Built-in default model",
                    isSelected: viewModel.sttProvider == .aliCloud,
                    isMuted: false,
                    actionTitle: "Use Alibaba Cloud"
                ),
                StudioModelCard(
                    id: StudioModelProviderID.doubaoRealtime.rawValue,
                    name: "Doubao Realtime ASR",
                    summary: "Low-latency streaming recognition through Doubao Speech Recognition 2.0 with ByteDance's native binary WebSocket protocol.",
                    badge: "API",
                    metadata: "Built-in default profile",
                    isSelected: viewModel.sttProvider == .doubaoRealtime,
                    isMuted: false,
                    actionTitle: "Use Doubao"
                )
            ]
        case .llm:
            return [
                StudioModelCard(
                    id: StudioModelProviderID.ollama.rawValue,
                    name: "Local Ollama",
                    summary: "Runs rewrite and edit commands locally, with optional automatic model preparation.",
                    badge: "Local",
                    metadata: viewModel.ollamaModel.isEmpty ? "Model not configured" : viewModel.ollamaModel,
                    isSelected: viewModel.llmProvider == .ollama,
                    isMuted: false,
                    actionTitle: "Use Local"
                ),
                StudioModelCard(
                    id: StudioModelProviderID.openAICompatible.rawValue,
                    name: "OpenAI-Compatible",
                    summary: "Connect remote chat-completions providers for persona rewriting and editing workflows.",
                    badge: "API",
                    metadata: viewModel.llmModel.isEmpty ? "Model not configured" : viewModel.llmModel,
                    isSelected: viewModel.llmProvider == .openAICompatible,
                    isMuted: false,
                    actionTitle: "Use Remote"
                )
            ]
        }
    }

    private var modelOverviewPanel: some View {
        StudioCard {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                            .fill(StudioTheme.accentSoft)
                            .frame(width: 46, height: 46)
                            .overlay(
                                Image(systemName: viewModel.modelDomain == .stt ? "waveform.and.mic" : "sparkles.rectangle.stack")
                                    .foregroundStyle(StudioTheme.accent)
                            )

                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(modelOverviewTitle)
                                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(modelOverviewSubtitle)
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }

                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        StudioPill(title: modelOverviewModePill, tone: modelOverviewModeTone, fill: modelOverviewModeFill)
                        StudioPill(title: modelOverviewProviderPill)
                        if let extraPill = modelOverviewExtraPill {
                            StudioPill(title: extraPill)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: StudioTheme.Spacing.small) {
                    Text(modelOverviewModelName)
                        .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(modelOverviewModelHint)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                    StudioButton(title: "Edit current provider", systemImage: nil, variant: .secondary) {
                        viewModel.focusModelProvider(activeModelProviderID)
                    }
                }
            }
        }
    }

    private var focusedProviderConfigurationPanel: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                            Text(focusedProviderTitle)
                                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(focusedProviderSubtitle)
                                .font(.studioBody(StudioTheme.Typography.bodySmall))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }

                        Spacer()

                        if viewModel.focusedModelProvider == activeModelProviderID {
                            StudioPill(
                                title: "Active",
                                tone: StudioTheme.success,
                                fill: StudioTheme.success.opacity(0.12)
                            )
                        } else {
                            StudioButton(title: "Use as Default", systemImage: "checkmark.circle.fill", variant: .secondary) {
                                applyFocusedProviderAsDefault()
                            }
                        }
                    }
                }

                focusedProviderForm

                if [StudioModelProviderID.whisperAPI, .multimodalLLM, .openAICompatible, .ollama, .aliCloud, .doubaoRealtime].contains(viewModel.focusedModelProvider) {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        StudioButton(title: "Save", systemImage: "checkmark", variant: .primary) {
                            viewModel.applyModelConfiguration()
                        }
                        if viewModel.focusedModelProvider == .openAICompatible || viewModel.focusedModelProvider == .ollama {
                            StudioButton(
                                title: viewModel.llmConnectionTestState == .testing ? "Testing..." : "Test Connection",
                                systemImage: viewModel.llmConnectionTestState == .testing ? nil : "network",
                                variant: .secondary,
                                isDisabled: viewModel.llmConnectionTestState == .testing,
                                isLoading: viewModel.llmConnectionTestState == .testing
                            ) {
                                viewModel.testLLMConnection()
                            }
                        }
                        Spacer()
                    }

                    if viewModel.focusedModelProvider == .openAICompatible || viewModel.focusedModelProvider == .ollama {
                        llmTestResultView
                    }
                }

                if viewModel.focusedModelProvider == .ollama {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        StudioButton(
                            title: viewModel.isPreparingOllama ? "Preparing..." : "Prepare Local Model",
                            systemImage: viewModel.isPreparingOllama ? nil : "arrow.down.circle",
                            variant: .primary
                        ) {
                            viewModel.prepareOllamaModel()
                        }

                        Text(viewModel.ollamaStatus)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }

                if viewModel.focusedModelProvider == .localSTT {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                            ProgressView(value: viewModel.localSTTPreparationProgress, total: 1)
                                .progressViewStyle(.linear)
                                .tint(viewModel.localSTTPreparationTint)

                            Text(viewModel.localSTTPreparationPercentText)
                                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }

                        Text(viewModel.localSTTPreparationDetail)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)

                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                                Text("Storage Path")
                                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)

                                Spacer(minLength: 0)

                                Button {
                                    viewModel.copyLocalSTTStoragePath()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                                .fill(StudioTheme.surfaceMuted)
                                        )
                                }
                                .buttonStyle(StudioInteractiveButtonStyle())

                                Button {
                                    viewModel.openLocalSTTStorageFolder()
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                                .fill(StudioTheme.surfaceMuted)
                                        )
                                }
                                .buttonStyle(StudioInteractiveButtonStyle())
                            }

                            Text(viewModel.localSTTStoragePath)
                                .font(.studioMono(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(viewModel.localSTTStatus)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }

            }
        }
    }

    @ViewBuilder
    private var focusedProviderForm: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
            switch viewModel.focusedModelProvider {
            case .appleSpeech:
                Text("Apple Speech is the quickest local option and requires no additional setup or downloads.")
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)

            case .localSTT:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                    Text("Local Model")
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)

                    ForEach(LocalSTTModel.allCases, id: \.self) { model in
                        localSTTModelOptionCard(model)
                    }
                }

            case .whisperAPI:
                StudioSuggestedTextInputCard(
                    label: "Transcription Endpoint",
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: Binding(get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL),
                    suggestions: whisperEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: "Model",
                    placeholder: OpenAIAudioModelCatalog.whisperModels[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions
                )
                StudioTextInputCard(label: "API Key", placeholder: "sk-...", text: Binding(get: { viewModel.whisperAPIKey }, set: viewModel.setWhisperAPIKey), secure: true)

            case .ollama:
                StudioSuggestedTextInputCard(
                    label: "Ollama Base URL",
                    placeholder: "http://127.0.0.1:11434",
                    text: Binding(get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL),
                    suggestions: ollamaEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: "Local Model",
                    placeholder: "qwen2.5:7b",
                    text: Binding(get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel),
                    suggestions: ollamaModelSuggestions
                )
                Toggle("Automatically install or pull the model when missing", isOn: Binding(get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup))
                    .toggleStyle(.switch)

            case .openAICompatible:
                StudioSuggestedTextInputCard(
                    label: "Chat Endpoint",
                    placeholder: "https://api.openai.com/v1",
                    text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                    suggestions: llmEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: "Model",
                    placeholder: "gpt-4o-mini",
                    text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                    suggestions: llmModelSuggestions
                )
                StudioTextInputCard(label: "API Key", placeholder: "sk-...", text: Binding(get: { viewModel.llmAPIKey }, set: viewModel.setLLMAPIKey), secure: true)

            case .multimodalLLM:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioSuggestedTextInputCard(
                        label: "API Endpoint",
                        placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                        text: Binding(get: { viewModel.multimodalLLMBaseURL }, set: viewModel.setMultimodalLLMBaseURL),
                        suggestions: multimodalEndpointSuggestions
                    )
                    StudioSuggestedTextInputCard(
                        label: "Model",
                        placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                        text: Binding(get: { viewModel.multimodalLLMModel }, set: viewModel.setMultimodalLLMModel),
                        suggestions: multimodalModelSuggestions
                    )
                    StudioTextInputCard(label: "API Key", placeholder: "sk-...", text: Binding(get: { viewModel.multimodalLLMAPIKey }, set: viewModel.setMultimodalLLMAPIKey), secure: true)
                    Text("Audio is base64-encoded and sent as input_audio to the configured chat/completions endpoint. When a persona is active, transcription and rewriting happen in a single call.")
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

            case .aliCloud:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(label: "API Key", placeholder: "sk-...", text: Binding(get: { viewModel.aliCloudAPIKey }, set: viewModel.setAliCloudAPIKey), secure: true) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://bailian.console.aliyun.com?tab=model#/api-key")!)
                        } label: {
                            Text("获取 API Key")
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

            case .doubaoRealtime:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(label: "App ID", placeholder: "APPID", text: Binding(get: { viewModel.doubaoAppID }, set: viewModel.setDoubaoAppID))
                    StudioTextInputCard(label: "Access Token", placeholder: "access-token", text: Binding(get: { viewModel.doubaoAccessToken }, set: viewModel.setDoubaoAccessToken), secure: true) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!)
                        } label: {
                            Text("查看接入文档")
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var llmTestResultView: some View {
        switch viewModel.llmConnectionTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing connection...")
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        case .success(let firstMs, let totalMs, let preview):
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.success)
                    Text("Connected · First token: \(firstMs)ms · Total: \(totalMs)ms")
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(StudioTheme.Spacing.small)
                        .background(
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                .fill(StudioTheme.surfaceMuted)
                        )
                }
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.danger)
                Text(message)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelRoutingPanel: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                StudioSectionTitle(title: "Routing behaviour")
                providerFactRow(title: modelRoutingPrimaryTitle, value: modelRoutingPrimaryValue)
                if let title = modelRoutingSecondaryTitle, let value = modelRoutingSecondaryValue {
                    providerFactRow(title: title, value: value)
                }

                HStack {
                    StudioButton(title: "Apply Configuration", systemImage: "bolt.fill", variant: .primary) {
                        viewModel.applyModelConfiguration()
                    }
                    if viewModel.modelDomain == .llm && viewModel.llmProvider == .ollama {
                        StudioButton(title: "Prepare Ollama", systemImage: nil, variant: .secondary) {
                            viewModel.prepareOllamaModel()
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func modelProviderSelectionCard(_ card: StudioModelCard) -> some View {
        let providerID = StudioModelProviderID(rawValue: card.id) ?? activeModelProviderID
        let isFocused = viewModel.focusedModelProvider == providerID

        return Button {
            viewModel.focusModelProvider(providerID)
        } label: {
            StudioCard(padding: StudioTheme.Insets.cardCompact) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.xSmall) {
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                            .fill(isFocused ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                            .frame(width: StudioTheme.ControlSize.modelProviderBadge, height: StudioTheme.ControlSize.modelProviderBadge)
                            .overlay(
                                Image(systemName: iconName(for: providerID))
                                    .font(.system(size: StudioTheme.ControlSize.modelProviderBadgeSymbol, weight: .semibold))
                                    .foregroundStyle(isFocused ? StudioTheme.accent : StudioTheme.textSecondary)
                            )

                        Text(card.name)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Circle()
                            .fill(card.isSelected ? StudioTheme.success : StudioTheme.border)
                            .frame(width: StudioTheme.ControlSize.modelProviderStatusDot, height: StudioTheme.ControlSize.modelProviderStatusDot)
                    }

                    Text(card.summary)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)

                    HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                        Text(card.metadata)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if card.isSelected {
                            StudioPill(
                                title: "Active",
                                tone: StudioTheme.success,
                                fill: StudioTheme.success.opacity(0.12)
                            )
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(isFocused ? StudioTheme.accent.opacity(0.62) : Color.clear, lineWidth: StudioTheme.BorderWidth.emphasis)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func providerFactRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 86, alignment: .leading)

            Text(value)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func localSTTModelOptionCard(_ model: LocalSTTModel) -> some View {
        let isSelected = viewModel.localSTTModel == model
        let specs = model.specs

        return Button {
            viewModel.setLocalSTTModel(model)
        } label: {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                        Text(model.displayName)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        Text(specs.summary)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        StudioPill(
                            title: "Selected",
                            tone: StudioTheme.accent,
                            fill: StudioTheme.accentSoft
                        )
                    }
                }

                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    localSTTSpecPill(specs.parameterInfo)
                    localSTTSpecPill(specs.sizeInfo)
                }
            }
            .padding(StudioTheme.Insets.cardCompact)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.65) : StudioTheme.border.opacity(0.75), lineWidth: isSelected ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func localSTTSpecPill(_ text: String) -> some View {
        Text(text)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, StudioTheme.Insets.pillHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioTheme.surface)
            )
    }

    private func providerIsConfigured(_ provider: StudioModelProviderID) -> Bool {
        switch provider {
        case .appleSpeech:
            return true
        case .localSTT:
            return true
        case .whisperAPI:
            return !viewModel.whisperBaseURL.isEmpty
        case .ollama:
            return !viewModel.ollamaModel.isEmpty
        case .openAICompatible:
            return !viewModel.llmBaseURL.isEmpty && !viewModel.llmModel.isEmpty
        case .multimodalLLM:
            return !viewModel.multimodalLLMBaseURL.isEmpty && !viewModel.multimodalLLMModel.isEmpty
        case .aliCloud:
            return !viewModel.aliCloudAPIKey.isEmpty
        case .doubaoRealtime:
            return !viewModel.doubaoAppID.isEmpty && !viewModel.doubaoAccessToken.isEmpty
        }
    }

    private func applyFocusedProviderAsDefault() {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            viewModel.setSTTModelSelection(.appleSpeech, suggestedModel: viewModel.whisperModel)
        case .localSTT:
            viewModel.setSTTProvider(.localModel)
        case .whisperAPI:
            viewModel.setSTTModelSelection(.whisperAPI, suggestedModel: viewModel.whisperModel.isEmpty ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel)
        case .ollama:
            viewModel.setLLMModelSelection(.ollama, suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel)
            viewModel.prepareOllamaModel()
        case .openAICompatible:
            viewModel.setLLMModelSelection(.openAICompatible, suggestedModel: viewModel.llmModel.isEmpty ? "gpt-4o-mini" : viewModel.llmModel)
        case .multimodalLLM:
            viewModel.setSTTModelSelection(.multimodalLLM, suggestedModel: viewModel.multimodalLLMModel.isEmpty ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel)
        case .aliCloud:
            viewModel.setSTTProvider(.aliCloud)
        case .doubaoRealtime:
            viewModel.setSTTProvider(.doubaoRealtime)
        }
    }

    private func iconName(for provider: StudioModelProviderID) -> String {
        switch provider {
        case .appleSpeech:
            return "waveform"
        case .localSTT:
            return "waveform.circle"
        case .whisperAPI:
            return "dot.radiowaves.left.and.right"
        case .ollama:
            return "cpu"
        case .openAICompatible:
            return "sparkles"
        case .multimodalLLM:
            return "brain.filled.head.profile"
        case .aliCloud:
            return "antenna.radiowaves.left.and.right"
        case .doubaoRealtime:
            return "bolt.horizontal.circle"
        }
    }

    private var modelProviderSectionTitle: String {
        viewModel.modelDomain == .stt ? "Speech providers" : "LLM providers"
    }

    private var modelProviderSectionSubtitle: String {
        viewModel.modelDomain == .stt
            ? "Choose the recognizer you want to default to, then configure credentials and fallback without leaving this page."
            : "Choose the runtime for rewrite and edit flows, then tune local or remote settings on the right."
    }

    private var modelOverviewTitle: String {
        viewModel.modelDomain == .stt ? "Default transcription stack" : "Default rewrite stack"
    }

    private var modelOverviewSubtitle: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return "Voice input stays on-device for predictable startup and lower friction."
        case .localSTT:
            return "Speech recognition is handled by a local runtime with curated downloadable models."
        case .whisperAPI:
            return "Speech recognition is routed to your configured remote transcription endpoint."
        case .ollama:
            return "Rewrite requests stay local and run through your Ollama runtime."
        case .openAICompatible:
            return "Rewrite requests are sent to your selected remote chat-completions provider."
        case .multimodalLLM:
            return "Audio is sent directly to a multimodal model — transcription and persona rewriting in one call."
        case .aliCloud:
            return "Speech recognition is streamed in real-time to Alibaba Cloud DashScope via WebSocket."
        case .doubaoRealtime:
            return "Speech recognition is streamed in real-time to Doubao Speech Recognition 2.0 via ByteDance WebSocket."
        }
    }

    private var modelOverviewProviderPill: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return "Apple Speech"
        case .localSTT:
            return "Local Model"
        case .whisperAPI:
            return "Whisper API"
        case .ollama:
            return "Ollama"
        case .openAICompatible:
            return "OpenAI-Compatible"
        case .multimodalLLM:
            return "Multimodal LLM"
        case .aliCloud:
            return "Alibaba Cloud ASR"
        case .doubaoRealtime:
            return "Doubao Realtime ASR"
        }
    }

    private var modelOverviewModePill: String {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return "Local"
        case .whisperAPI, .openAICompatible, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return "Remote"
        }
    }

    private var modelOverviewModeTone: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return StudioTheme.success
        case .whisperAPI, .openAICompatible, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return StudioTheme.accent
        }
    }

    private var modelOverviewModeFill: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return StudioTheme.success.opacity(0.12)
        case .whisperAPI, .openAICompatible, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return StudioTheme.accentSoft
        }
    }

    private var modelOverviewExtraPill: String? {
        if viewModel.modelDomain == .stt {
            return viewModel.appleSpeechFallback ? "Fallback enabled" : "Fallback off"
        }

        return providerIsConfigured(activeModelProviderID) ? "Configured" : "Needs setup"
    }

    private var modelOverviewModelName: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return "Apple Speech"
        case .localSTT:
            return viewModel.localSTTModel.displayName
        case .whisperAPI:
            return viewModel.whisperModel.isEmpty ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel
        case .ollama:
            return viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
        case .openAICompatible:
            return viewModel.llmModel.isEmpty ? "gpt-4o-mini" : viewModel.llmModel
        case .multimodalLLM:
            return viewModel.multimodalLLMModel.isEmpty ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel
        case .aliCloud:
            return AliCloudASRDefaults.model
        case .doubaoRealtime:
            return "Doubao Speech Recognition 2.0"
        }
    }

    private var modelOverviewModelHint: String {
        providerIsConfigured(activeModelProviderID) ? "Ready for use" : "Configuration still needed"
    }

    private var focusedProviderTitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            return "Apple Speech"
        case .localSTT:
            return "Local Speech Models"
        case .whisperAPI:
            return "Whisper API"
        case .ollama:
            return "Local Ollama"
        case .openAICompatible:
            return "OpenAI-Compatible"
        case .multimodalLLM:
            return "Multimodal LLM"
        case .aliCloud:
            return "Alibaba Cloud ASR"
        case .doubaoRealtime:
            return "Doubao Realtime ASR"
        }
    }

    private var focusedProviderSubtitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            return "Use this when you want offline-first dictation with almost no setup."
        case .localSTT:
            return "Use this when you want downloadable local ASR models with better multilingual coverage than the system recognizer."
        case .whisperAPI:
            return "Use this when you want better model control or your own speech gateway."
        case .ollama:
            return "Use this when local privacy matters for rewrite and editing flows."
        case .openAICompatible:
            return "Use this when you want flexible remote LLM access for rewriting and assistant actions."
        case .multimodalLLM:
            return "Use this when you want the fastest end-to-end path — audio goes directly to a multimodal model that transcribes and rewrites in one shot."
        case .aliCloud:
            return "Use this when you want low-latency real-time streaming recognition via Alibaba Cloud DashScope with FunASR or Qwen3 ASR models."
        case .doubaoRealtime:
            return "Use this when you want the lowest-latency cloud dictation path through Doubao Speech Recognition 2.0 and ByteDance's streaming ASR protocol."
        }
    }

    private var modelRoutingPrimaryTitle: String {
        viewModel.modelDomain == .stt ? "Primary recognizer" : "Primary runtime"
    }

    private var modelRoutingPrimaryValue: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return "Apple Speech handles dictation directly on your Mac."
        case .localSTT:
            return "The embedded local STT service handles dictation with your selected downloadable model."
        case .whisperAPI:
            return "Whisper API handles dictation through the configured transcription endpoint."
        case .ollama:
            return "Ollama handles rewrite and edit requests locally."
        case .openAICompatible:
            return "The remote chat-completions endpoint handles rewrite and edit requests."
        case .multimodalLLM:
            return "A multimodal LLM handles the full transcription pipeline. When a persona is active, rewriting is folded into the same call."
        case .aliCloud:
            return "Alibaba Cloud DashScope handles real-time streaming ASR via WebSocket."
        case .doubaoRealtime:
            return "Doubao Speech Recognition 2.0 handles real-time streaming ASR via ByteDance's binary WebSocket protocol."
        }
    }

    private var modelRoutingSecondaryTitle: String? {
        if viewModel.modelDomain == .stt {
            return "Fallback"
        }

        return activeModelProviderID == .ollama ? "Local setup" : "Readiness"
    }

    private var modelRoutingSecondaryValue: String? {
        if viewModel.modelDomain == .stt {
            return viewModel.appleSpeechFallback
                ? "If remote transcription fails, the app can fall back to Apple Speech automatically."
                : "Automatic fallback is currently disabled."
        }

        if activeModelProviderID == .ollama {
            return viewModel.ollamaAutoSetup
                ? "Missing local models can be prepared automatically when needed."
                : "Local model setup is manual until you enable auto preparation."
        }

        return providerIsConfigured(.openAICompatible)
            ? "Remote endpoint and model are set. API key is optional in the current implementation."
            : "Add a remote endpoint and model before using cloud rewrite."
    }

}
