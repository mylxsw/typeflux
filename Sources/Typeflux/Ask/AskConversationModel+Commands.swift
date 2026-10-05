import AppKit
import Foundation

/// What slash commands read and change outside the conversation model. The
/// window controller wires it to the tools, MCP settings and memory notes;
/// tests pass their own.
@MainActor
struct AskCommandSources {
    var skills: @MainActor () -> [AskSkill] = { [] }
    var mcpServers: @MainActor () -> [AskMCPServerSummary] = { [] }
    var remember: @MainActor (String) throws -> Void = { _ in }
    /// Whether new conversations are kept on this Mac by default.
    var privateByDefault: @MainActor () -> Bool = { false }
    /// Built-in skill names, for the "Built-in" badge.
    var builtinSkillNames: @MainActor () -> Set<String> = { Set(AskBuiltinSkills.all.map(\.name)) }
    var copy: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension AskConversationModel {
    static let maximumChosenSkills = 3
    static let maximumChosenServers = 5

    private func currentDraft(launcher: Bool) -> AskDraft { launcher ? launcherDraft : draft }
    private func updateDraft(launcher: Bool, _ change: (inout AskDraft) -> Void) {
        if launcher { change(&launcherDraft) } else { change(&draft) }
        persistDrafts()
    }

    /// The latest answer in the conversation on screen, if any.
    var latestAnswer: AskMessage? {
        selected?.messages.last { $0.role == "assistant" && !$0.text.isEmpty }
    }

    func commandContext(launcher: Bool) -> AskCommandContext {
        let value = currentDraft(launcher: launcher)
        let reference = modelReference(launcher: launcher)
        let capability = screenshotCapability(launcher: launcher)
        let builtins = commandSources.builtinSkillNames()
        var context = AskCommandContext()
        context.launcher = launcher
        context.busy = !launcher && (isBusy || isLoadingSelection)
        context.hasAnswer = !launcher && latestAnswer != nil
        // Only models that can take this draft, as the model menu offers them.
        let providers = modelLibrary.selectableProviders(loggedIn: cloudAvailable(launcher: launcher),
                                                         hasImage: requiresVision(launcher: launcher))
        context.models = providers.flatMap { $0.models.map(\.reference) }.map { reference in
            .init(reference: reference, name: modelLibrary.name(for: reference),
                  vision: modelLibrary.imageCapability(reference) == .supported)
        }
        context.currentModel = reference
        context.reasoningLevels = reasoningLevels(launcher: launcher)
        context.reasoningAvailable = !context.reasoningLevels.isEmpty
        context.reasoning = displayedReasoningEffort(launcher: launcher)
        context.localMode = storesLocally(launcher: launcher)
        context.storageLocked = canChangeStorage(launcher: launcher) ? nil
            : L(isSignedIn ? "ask.storage.locked" : "ask.storage.signedOut")
        context.screenshotOn = value.includeScreenshot
        context.screenshotUnavailable = capability == .supported ? nil : capability.hint
        context.selectionAvailable = value.selection?.isEmpty == false
        context.selectionOn = value.selection?.isEmpty == false && value.selectionOff != true
        context.memoryOn = !memorySwitchedOff(launcher: launcher)
        context.skills = commandSources.skills().map {
            AskSkillSummary(name: $0.name, description: $0.description, builtin: builtins.contains($0.name))
        }
        context.mcpServers = commandSources.mcpServers()
        context.chosenSkills = value.skills ?? []
        context.chosenServers = value.mcpServers ?? []
        context.recent = recentCommands
        if launcher {
            let language = AppLocalization.shared.language
            context.keywords = launcherKeywords.filter(\.enabled).compactMap { keyword in
                plugins.plugin(for: keyword).map { plugin in
                    .init(keyword: keyword.keyword, id: keyword.id, title: plugin.title,
                          detail: plugin.chipDetail(for: keyword, language: language), symbol: plugin.symbol)
                }
            }
        }
        return context
    }

    /// Runs a chosen command. `argument` is the text after the name for
    /// commands that take one, such as "/remember".
    func runCommand(_ command: AskCommand, argument: String? = nil, launcher: Bool) {
        guard command.enabled else { return }
        if !command.plain {
            recentCommands = Array(([command.name] + recentCommands.filter { $0 != command.name }).prefix(3))
        }
        switch command.action {
        case .newConversation:
            newConversation()
            if launcher { onShowConversation?() }
        case .search:
            if launcher { onShowConversation?() }
            searchRequest += 1
        case .regenerate:
            if let answer = latestAnswer, canRegenerate(answer) { regenerate(answer.id) }
        case .copyAnswer:
            if let answer = latestAnswer {
                commandSources.copy(answer.text)
                confirm(L("ask.command.copied"))
            }
        case .model, .reasoning:
            break // The palette opens their choices.
        case let .pickModel(reference):
            selectModel(reference, launcher: launcher)
            confirm(L("ask.command.modelChanged", modelLibrary.name(for: reference)))
        case let .pickReasoning(effort):
            reasoningEffort = effort
            confirm(L("ask.command.reasoningChanged", effort.label))
        case .localMode:
            guard canChangeStorage(launcher: launcher) else { return }
            let on = !storesLocally(launcher: launcher)
            setStoresLocally(on, launcher: launcher)
            confirm(L(on ? "ask.command.localOn" : "ask.command.localOff"))
        case .attachFiles:
            pickAttachments(folders: false, launcher: launcher)
        case .attachFolder:
            pickAttachments(folders: true, launcher: launcher)
        case .screenshot:
            let on = !currentDraft(launcher: launcher).includeScreenshot
            if on { switchToVisionModelIfNeeded(launcher: launcher, needsVision: true) }
            guard !on || screenshotCapability(launcher: launcher) == .supported else { return }
            updateDraft(launcher: launcher) { $0.includeScreenshot = on }
            if on, currentDraft(launcher: launcher).screenshot == nil { Task { await refreshScreenshot(launcher: launcher) } }
            confirm(L(on ? "ask.command.screenshotOn" : "ask.command.screenshotOff"))
        case .selection:
            let off = currentDraft(launcher: launcher).selectionOff != true
            updateDraft(launcher: launcher) { $0.selectionOff = off ? true : nil }
            confirm(L(off ? "ask.command.selectionOff" : "ask.command.selectionOn"))
        case .memory:
            toggleMemory(launcher: launcher)
            persistDrafts()
            confirm(L(memorySwitchedOff(launcher: launcher) ? "ask.command.memoryOff" : "ask.command.memoryOn"))
        case .remember:
            let text = (argument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            do {
                try commandSources.remember(text)
                confirm(L("ask.command.remembered"))
            } catch {
                self.error = error.localizedDescription
            }
        case let .suggestion(key):
            guard let suggestion = AskSuggestion.all.first(where: { $0.key == key }) else { return }
            if suggestion.screenshot { attachScreenshotForSuggestion(launcher: launcher) }
            updateDraft(launcher: launcher) { draft in
                let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.text = typed.isEmpty ? suggestion.title : typed + " " + suggestion.title
            }
        case let .skill(name):
            toggleChoice(name, keyPath: \.skills, limit: Self.maximumChosenSkills, launcher: launcher)
        case let .mcpServer(name):
            toggleChoice(name, keyPath: \.mcpServers, limit: Self.maximumChosenServers, launcher: launcher)
        case let .keyword(id):
            // What is left in the editor becomes the keyword's text.
            guard launcher, let keyword = launcherKeywords.first(where: { $0.id == id && $0.enabled }) else { return }
            plugins.enter(keyword)
            plugins.update(text: launcherDraft.text, selection: launcherDraft.sentSelection,
                           language: AppLocalization.shared.language)
        case .help:
            break // The palette shows every command.
        case .settings:
            onOpenSettings?(.agent)
        }
    }

    /// Adds a skill or server chip, or removes it when it is already chosen.
    private func toggleChoice(_ name: String, keyPath: WritableKeyPath<AskDraft, [String]?>, limit: Int, launcher: Bool) {
        var names = currentDraft(launcher: launcher)[keyPath: keyPath] ?? []
        if let index = names.firstIndex(of: name) {
            names.remove(at: index)
        } else {
            guard names.count < limit else { confirm(L("ask.command.tooManyChoices", limit)); return }
            names.append(name)
        }
        updateDraft(launcher: launcher) { $0[keyPath: keyPath] = names.isEmpty ? nil : names }
    }

    func removeChoice(skill name: String, launcher: Bool) {
        updateDraft(launcher: launcher) { draft in
            draft.skills?.removeAll { $0 == name }
            if draft.skills?.isEmpty == true { draft.skills = nil }
        }
    }

    func removeChoice(mcpServer name: String, launcher: Bool) {
        updateDraft(launcher: launcher) { draft in
            draft.mcpServers?.removeAll { $0 == name }
            if draft.mcpServers?.isEmpty == true { draft.mcpServers = nil }
        }
    }

    /// The chosen skills with their instructions; a skill removed since is dropped.
    func skillUses(_ names: [String]?) -> [AskSkillUse]? {
        guard let names, !names.isEmpty else { return nil }
        let library = commandSources.skills()
        let uses = names.compactMap { name in
            library.first { $0.name == name }.map { AskSkillUse(name: $0.name, instructions: $0.body) }
        }
        return uses.isEmpty ? nil : uses
    }

    /// Shows a short confirmation in the composer's footer, then clears it unless
    /// a newer one replaced it. VoiceOver hears it, since the note is visual only.
    /// The reasoning levels this composer's model offers, lightest first.
    func reasoningLevels(launcher: Bool) -> [AskReasoningEffort] {
        AskReasoningEffort.levels(for: modelLibrary.registry.resolve(modelReference(launcher: launcher))?.1)
    }

    /// The effort the next message uses with this composer's model: the chosen one,
    /// or the closest level the model offers.
    func displayedReasoningEffort(launcher: Bool) -> AskReasoningEffort {
        reasoningEffort.nearest(in: reasoningLevels(launcher: launcher))
    }

    /// A model with fewer levels moves the choice to its closest level, and says so once.
    func snapReasoningEffort(launcher: Bool) {
        let levels = reasoningLevels(launcher: launcher)
        let snapped = reasoningEffort.nearest(in: levels)
        guard !levels.isEmpty, snapped != reasoningEffort else { return }
        let from = reasoningEffort
        reasoningEffort = snapped
        confirm(L("ask.reasoning.snapped", from.label, snapped.label))
    }

    func confirm(_ text: String, for duration: Duration = .milliseconds(1600)) {
        commandFeedback = text
        AskAnnouncer.announce(text)
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.commandFeedback == text { self?.commandFeedback = nil }
        }
    }
}
