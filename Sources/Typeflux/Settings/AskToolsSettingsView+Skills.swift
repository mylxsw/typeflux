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
        .buttonStyle(ModelActionStyle())
        Button {
            installError = nil
            installURL = ""
            showingInstall = true
        } label: {
            Label(L("ask.settings.skills.install"), systemImage: "arrow.down.circle")
        }
        .buttonStyle(ModelActionStyle(primary: true))
    }

    @ViewBuilder var skillSections: some View {
        let visible = Self.filteredSkills(skillList, disabled: disabledSkills, query: skillQuery, filter: skillFilter)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsSearchBox(placeholder: L("agent.skills.search"), text: $skillQuery)
                ModelSegmentedControl(
                    options: [(label: L("agent.filter.all"), value: SkillFilter.all),
                              (label: L("agent.filter.enabled"), value: SkillFilter.enabled),
                              (label: L("agent.filter.disabled"), value: SkillFilter.disabled)],
                    selection: $skillFilter
                )
            }
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        AgentSettingsEmptyRow(text: L("agent.skills.noMatch"))
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.name) { index, skill in
                        if index > 0 { ModelRowDivider(leading: 66) }
                        skillRow(skill)
                    }
                }
            }
        }
        .sheet(isPresented: $showingInstall) { installSheet }
        .sheet(item: $inspectedSkill) { item in skillDetail(item.name) }
        .alert(L("ask.settings.skills.actionFailed"), isPresented: Binding(
            get: { skillActionError != nil }, set: { if !$0 { skillActionError = nil } }
        )) {
            Button(L("common.ok")) { skillActionError = nil }
        } message: {
            Text(skillActionError ?? "")
        }
        .alert(L("ask.settings.skills.removeTitle"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button(L("ask.remove"), role: .destructive) {
                if let skill = pendingRemoval { removeSkill(skill) }
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
        if skill.directory == nil { return (L("ask.settings.skills.builtin"), false) }
        return skills.source(of: skill) == nil ? (L("ask.settings.skills.local"), false) : ("GitHub", true)
    }

    private func skillRow(_ skill: AskSkill) -> some View {
        let badge = skillBadge(skill)
        return Button {
            inspectedSkill = InspectedSkill(name: skill.name)
        } label: {
            HStack(spacing: 14) {
                ModelIconTile {
                    Image(systemName: "wand.and.stars").font(.system(size: 15))
                        .foregroundStyle(disabledSkills.contains(skill.name) ? StudioTheme.textTertiary : ModelVisualStyle.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                        ModelUsageBadge(text: badge.text, accent: badge.accent)
                    }
                    Text(skill.displayDescription).font(.system(size: StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                // A turned-off skill is neither offered to the model nor loaded.
                Toggle("", isOn: Binding(get: { !disabledSkills.contains(skill.name) },
                                         set: { setSkill(skill.name, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(skill.name)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12).frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                enabled: Binding(get: { !disabledSkills.contains(skill.name) }, set: { setSkill(skill.name, enabled: $0) }),
                canRollback: skills.hasPreviousVersion(of: skill),
                onRollback: { rollbackSkill(skill) },
                onReveal: skill.directory.map { directory in { NSWorkspace.shared.activateFileViewerSelecting([directory]) } },
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
        guard let target = try? AskSkillInstaller.parse(input) else { return (L("ask.skills.install.invalidURL"), false) }
        return (L("agent.skills.install.preview", "\(target.owner)/\(target.repository)",
                  target.ref ?? L("agent.skills.install.defaultBranch"),
                  target.path.isEmpty ? L("agent.skills.install.root") : target.path), true)
    }

    var installSheet: some View {
        let preview = Self.installPreview(installURL)
        return VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.settings.skills.installTitle"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            TextField("https://github.com/owner/repo/tree/main/skills/name", text: $installURL)
                .textFieldStyle(ModelFieldStyle())
                .disabled(installing)
                .onSubmit { startInstall() }
            if let preview {
                Text(preview.text).font(.system(size: 12))
                    .foregroundStyle(preview.valid ? StudioTheme.textSecondary : StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(L("ask.settings.skills.installWarning")).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let installError {
                Text(installError).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { installTask?.cancel(); showingInstall = false }
                    .buttonStyle(ModelActionStyle())
                Button {
                    startInstall()
                } label: {
                    HStack(spacing: 6) {
                        if installing { ProgressView().controlSize(.small) }
                        Text(L(installing ? "ask.settings.skills.installing" : "ask.settings.skills.installAction"))
                    }
                }
                .buttonStyle(ModelActionStyle(primary: true))
                .disabled(installing || preview?.valid != true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(ModelVisualStyle.canvas)
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
            if settings.askDisabledSkills.contains(skill.name) { setSkill(skill.name, enabled: true) }
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

/// Everything known about one skill, with its enable switch and maintenance actions.
struct AgentSkillDetailView: View {
    let skill: AskSkill
    let badge: (text: String, accent: Bool)
    let source: AskSkillSource?
    @Binding var enabled: Bool
    let canRollback: Bool
    let onRollback: () -> Void
    let onReveal: (() -> Void)?
    let onRemove: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ModelIconTile(size: 38) {
                    Image(systemName: "wand.and.stars").font(.system(size: 17)).foregroundStyle(ModelVisualStyle.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                    ModelUsageBadge(text: badge.text, accent: badge.accent)
                }
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(enabled ? "agent.filter.enabled" : "agent.filter.disabled"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                    Text(L(enabled ? "agent.skills.enabledHint" : "agent.skills.disabledHint"))
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).accessibilityLabel(skill.name)
            }
            .padding(12)
            .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(skill.displayDescription).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                if let source {
                    detailRow(L("agent.skills.repository"), source.repository)
                    detailRow(L("agent.skills.version"),
                              "\(source.ref) · \(source.commit.map { String($0.prefix(7)) } ?? L("ask.settings.skills.unverifiedVersion"))")
                    detailRow(L("agent.skills.path"), source.path.isEmpty ? "/" : source.path)
                } else if skill.directory == nil {
                    detailRow(L("agent.skills.source"), L("agent.skills.builtinSource"))
                } else if let directory = skill.directory {
                    detailRow(L("agent.skills.path"), directory.path)
                }
            }
            if let declared = source?.declaredPermissions, !declared.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("agent.skills.declared")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    AgentFlowLayout { ForEach(declared, id: \.self) { AgentFactChip(text: $0) } }
                    Text(L("agent.skills.declaredHint")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            HStack(spacing: 8) {
                if canRollback {
                    Button(action: onRollback) { Label(L("ask.settings.skills.rollback"), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ModelActionStyle())
                }
                if let onReveal {
                    Button(L("agent.skills.reveal"), action: onReveal).buttonStyle(ModelActionStyle())
                }
                Spacer()
                if let onRemove {
                    Button(role: .destructive, action: onRemove) { Label(L("ask.remove"), systemImage: "trash") }
                        .buttonStyle(ModelActionStyle())
                }
                Button(L("common.done"), action: onClose).buttonStyle(ModelActionStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(ModelVisualStyle.canvas)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioTheme.textPrimary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
