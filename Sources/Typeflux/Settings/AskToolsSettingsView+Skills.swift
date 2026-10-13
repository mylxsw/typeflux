import AppKit
import SwiftUI

/// The Skills pane: list, search, details, install, rollback and removal.
extension AskToolsSettingsView {
    @ViewBuilder var skillHeaderActions: some View {
        Button {
            openSkillsFolder()
        } label: {
            Label(L("ask.settings.skills.open"), systemImage: "folder")
        }
        .buttonStyle(.bordered)
        Button {
            installError = nil
            installURL = ""
            showingInstall = true
        } label: {
            Label(L("ask.settings.skills.install"), systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder var skillSections: some View {
        let visible = Self.filteredSkills(
            skillList,
            disabled: disabledSkills,
            query: toolbarQuery ?? searchQuery.wrappedValue,
            filter: skillFilter
        )
        Group {
            Section {
                TypefluxSegmentedControl(AgentCapability.skills.title, selection: $skillFilter) {
                    Text(L("agent.filter.all")).tag(SkillFilter.all)
                    Text(L("agent.filter.enabled")).tag(SkillFilter.enabled)
                    Text(L("agent.filter.disabled")).tag(SkillFilter.disabled)
                }
            }
            Section {
                if visible.isEmpty {
                    TypefluxEmptyState(L("agent.skills.noMatch"), systemImage: "wand.and.stars",
                                       description: toolbarQuery ?? searchQuery.wrappedValue)
                }
                ForEach(visible, id: \.name) { skillRow($0) }
            }
        }
        .sheet(isPresented: $showingInstall) { installSheet }
        .sheet(item: $inspectedSkill) { item in skillDetail(item.name) }
        .alert(L("ask.settings.skills.actionFailed"), isPresented: Binding(
            get: { skillActionError != nil }, set: {
                if !$0 {
                    skillActionError = nil
                }
            }
        )) {
            Button(L("common.ok")) { skillActionError = nil }
        } message: {
            Text(skillActionError ?? "")
        }
        .alert(L("ask.settings.skills.removeTitle"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: {
                if !$0 {
                    pendingRemoval = nil
                }
            }
        )) {
            Button(L("ask.remove"), role: .destructive) {
                if let skill = pendingRemoval {
                    removeSkill(skill)
                }
                pendingRemoval = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(String(format: L("ask.settings.skills.removeMessage"), pendingRemoval?.name ?? ""))
        }
    }

    /// Skills matching the search text (name or description) and the enabled filter.
    static func filteredSkills(_ skills: [AskSkill], disabled: Set<String>, query: String,
                               filter: SkillFilter) -> [AskSkill] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.filter { skill in
            let matches = text.isEmpty || skill.name.localizedCaseInsensitiveContains(text)
                || skill.displayDescription.localizedCaseInsensitiveContains(text)
            switch filter {
            case .all: return matches
            case .enabled: return matches && !disabled.contains(skill.name)
            case .disabled: return matches && disabled.contains(skill.name)
            }
        }
    }

    func skillBadge(_ skill: AskSkill) -> (text: String, accent: Bool) {
        if skill.directory == nil {
            return (L("ask.settings.skills.builtin"), false)
        }
        return skills.source(of: skill) == nil ? (L("ask.settings.skills.local"), false) : ("GitHub", true)
    }

    private func skillRow(_ skill: AskSkill) -> some View {
        let badge = skillBadge(skill)
        return HStack(spacing: 12) {
            Button { inspectedSkill = InspectedSkill(name: skill.name) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(skill.name, systemImage: "wand.and.stars").font(.body)
                    Text(badge.text + " · " + skill.displayDescription).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless)
            Toggle(skill.name, isOn: Binding(get: { !disabledSkills.contains(skill.name) },
                                             set: { setSkill(skill.name, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).accessibilityLabel(skill.name)
        }
        .help(skills.source(of: skill).map(Self.skillSourceDescription) ?? "")
    }

    static func skillSourceDescription(_ source: AskSkillSource) -> String {
        let version = source.commit ?? L("ask.settings.skills.unverifiedVersion")
        let declarations = (source.declaredPermissions ?? []).joined(separator: ", ")
        return "\(source.repository)@\(source.ref)\n\(version)\n\(source.path)"
            + (declarations.isEmpty ? "" : "\n" + L("ask.settings.skills.declarations") + " " + declarations)
    }

    @ViewBuilder private func skillDetail(_ name: String) -> some View {
        if let skill = skillList.first(where: { $0.name == name }) {
            AgentSkillDetailView(
                skill: skill,
                badge: skillBadge(skill),
                source: skills.source(of: skill),
                enabled: Binding(get: { !disabledSkills.contains(skill.name) }, set: { setSkill(skill.name,
                                                                                                enabled: $0) }),
                canRollback: skills.hasPreviousVersion(of: skill),
                onRollback: { rollbackSkill(skill) },
                onReveal: skill.directory
                    .map { directory in { NSWorkspace.shared.activateFileViewerSelecting([directory]) } },
                onRemove: skill.directory == nil ? nil : {
                    inspectedSkill = nil
                    pendingRemoval = skill
                },
                onClose: { inspectedSkill = nil }
            )
        }
    }

    func rollbackSkill(_ skill: AskSkill) {
        do {
            try skills.rollback(skill)
            reload()
        } catch {
            skillActionError = error.localizedDescription
        }
    }

    /// Describes where a GitHub link would install from, or why it cannot be used.
    static func installPreview(_ input: String) -> (text: String, valid: Bool)? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let target = try? AskSkillInstaller.parse(input) else { return (L("ask.skills.install.invalidURL"),
                                                                              false) }
        return (L("agent.skills.install.preview", "\(target.owner)/\(target.repository)",
                  target.ref ?? L("agent.skills.install.defaultBranch"),
                  target.path.isEmpty ? L("agent.skills.install.root") : target.path), true)
    }

    var installSheet: some View {
        let preview = Self.installPreview(installURL)
        return TypefluxSheet(title: L("ask.settings.skills.installTitle"), cancelTitle: L("common.cancel"),
                             confirmTitle: L(installing ? "ask.settings.skills.installing" :
                                 "ask.settings.skills.installAction"),
                             isConfirmEnabled: !installing && preview?.valid == true,
                             cancel: { installTask?.cancel(); showingInstall = false }, confirm: startInstall,
                             content: {
                                 TextField("https://github.com/owner/repo/tree/main/skills/name", text: $installURL)
                                     .textFieldStyle(.roundedBorder).disabled(installing)
                                     .accessibilityLabel(L("ask.settings.skills.installTitle"))
                                     .onSubmit { startInstall() }
                                 if let preview {
                                     Text(preview.text).font(.subheadline)
                                         .foregroundStyle(preview.valid ? TypefluxColor.secondaryLabel
                                             .color : TypefluxColor.danger.color)
                                         .fixedSize(horizontal: false, vertical: true)
                                 }
                                 Label(L("ask.settings.skills.installWarning"), systemImage: "exclamationmark.triangle")
                                     .font(.subheadline).foregroundStyle(TypefluxColor.warning.color)
                                 if installing {
                                     ProgressView().controlSize(.small)
                                 }
                                 if let installError {
                                     Text(installError).font(.subheadline).foregroundStyle(TypefluxColor.danger.color)
                                 }
                             })
                             .frame(width: 480)
                             .onDisappear { installTask?.cancel() }
    }

    func startInstall() {
        let url = installURL
        guard !installing, Self.installPreview(url)?.valid == true else { return }
        installing = true
        installError = nil
        installTask = Task { @MainActor in
            defer { installing = false; installTask = nil }
            do {
                _ = try await AskSkillInstaller(library: skills).install(from: url)
                guard !Task.isCancelled else { return }
                reload()
                showingInstall = false
            } catch is CancellationError {
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    func removeSkill(_ skill: AskSkill) {
        do {
            try skills.remove(skill)
            // Explicit removal resets the name preference; updates and rollback preserve it.
            if settings.askDisabledSkills.contains(skill.name) {
                setSkill(skill.name, enabled: true)
            }
            reload()
        } catch {
            skillActionError = error.localizedDescription
        }
    }

    func openSkillsFolder() {
        try? FileManager.default.createDirectory(at: skills.userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skills.userDirectory)
    }
}
