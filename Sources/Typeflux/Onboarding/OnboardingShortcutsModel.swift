import AppKit
import Combine

@MainActor
final class OnboardingShortcutsModel: ObservableObject {
    weak var session: OnboardingViewModel?
    let shortcuts: HotkeySettingsModel
    let recorder = HotkeyRecorder()
    @Published var canContinue: Bool? = true
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?
    @Published var recordingTarget: HotkeyTarget?
    @Published var guideVisible = false
    @Published private(set) var errors: [HotkeyTarget: String] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private let openKeyboardSettings: () -> Void
    private let systemReader: () -> SystemSymbolicHotkeys
    private var systemShortcuts: SystemSymbolicHotkeys

    static let targets: [HotkeyTarget] = [.builtIn(.activation), .builtIn(.auxiliary), .builtIn(.persona),
                                          .builtIn(.ask), .action(.ring), .builtIn(.history), .builtIn(.screenshot),
                                          .action(.translate)]

    init(session: OnboardingViewModel, systemReader: @escaping () -> SystemSymbolicHotkeys = { .current },
         openKeyboardSettings: (() -> Void)? = nil) {
        self.session = session
        self.openKeyboardSettings = openKeyboardSettings ?? { [weak session] in session?.openKeyboardSystemSettings() }
        self.systemReader = systemReader
        systemShortcuts = systemReader()
        shortcuts = HotkeySettingsModel(settingsStore: session.settingsStore, workflows: .shared)
        shortcuts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    static func text(_ key: String, arguments: [CVarArg] = []) -> String {
        OnboardingStrings.text(key, table: "OnboardingShortcuts", arguments: arguments)
    }

    func binding(_ target: HotkeyTarget) -> HotkeyBinding? {
        shortcuts.row(for: target)?.binding
    }

    func refresh() {
        session?.refreshGlobeKeyState()
        systemShortcuts = systemReader()
        shortcuts.reload()
        objectWillChange.send()
    }

    func isGlobeConflict(_ target: HotkeyTarget) -> Bool {
        guard session?.isGlobeKeyReady == false, let binding = binding(target) else { return false }
        return binding.keyCode == HotkeyBinding.functionKeyCode
            && binding.modifierFlags == NSEvent.ModifierFlags.function.rawValue
    }

    func conflict(_ target: HotkeyTarget) -> String? {
        if let error = errors[target] {
            return error
        }
        guard let binding = binding(target) else { return nil }
        if let problem = shortcuts.check(binding, for: target).problem {
            return describe(problem)
        }
        if isGlobeConflict(target) {
            return Self.text("fnConflict")
        }
        if systemShortcuts.contains(binding) {
            return Self.text(
                "systemConflict",
                arguments: [binding.keyCode == 49 && binding.modifierFlags == NSEvent.ModifierFlags.command
                    .rawValue ? "Spotlight" : HotkeyFormat.display(binding)]
            )
        }
        return nil
    }

    var conflictCount: Int {
        Self.targets.filter { conflict($0) != nil }.count
    }

    func describe(_ problem: HotkeyConflictChecker.Problem) -> String {
        if case let .taken(owner) = problem {
            let name: String = switch owner {
            case let .builtIn(key): Self.text(key.rawValue)
            case let .action(action) where Self.targets.contains(owner): Self.text(action.rawValue)
            default: HotkeyConflictMessages.name(of: owner, in: shortcuts.settingsStore)
            }
            return Self.text("internalConflict", arguments: [name])
        }
        return Self.text("needsModifier")
    }

    func startRecording(_ target: HotkeyTarget) {
        stopRecording()
        recordingTarget = target
        errors[target] = nil
        isBusy = true
        recorder.start(supportsAuxiliaryBindings: target == .builtIn(.auxiliary), onCancel: { [weak self] in
            self?.stopRecording()
        }) { [weak self] binding in
            self?.stopRecording()
            self?.apply(binding, to: target, recorded: true)
        }
    }

    func stopRecording() {
        recorder.stop()
        recordingTarget = nil
        isBusy = false
    }

    @discardableResult
    func apply(_ binding: HotkeyBinding?, to target: HotkeyTarget, recorded: Bool = false) -> Bool {
        stopRecording()
        if let binding {
            let voice = target == .builtIn(.activation) || target == .builtIn(.auxiliary)
            if recorded, !voice {
                let hasModifier = binding.modifierFlags != 0
                let isFunctionKey = HotkeyConflictChecker.functionKeyCodes.contains(binding.keyCode)
                guard !binding.isModifierOnlyTrigger, !binding.isModifierDoubleTapTrigger,
                      hasModifier || isFunctionKey else {
                    errors[target] = Self.text("needsModifier")
                    return false
                }
            }
            if let problem = shortcuts.check(binding, for: target).problem {
                errors[target] = describe(problem)
                return false
            }
        }
        write(binding, to: target)
        errors[target] = nil
        refresh()
        return true
    }

    private func write(_ binding: HotkeyBinding?, to target: HotkeyTarget) {
        switch target {
        case let .builtIn(key): shortcuts.settingsStore.setHotkey(binding, for: key)
        case let .action(key): shortcuts.settingsStore.setHotkey(binding, for: key)
        case .keyword: break
        }
    }

    func restore(_ target: HotkeyTarget) {
        let value: HotkeyBinding? = switch target {
        case let .builtIn(key): key.defaultBinding
        case .action(.ring): RingConfiguration.defaultHotkey
        default: nil
        }
        apply(value, to: target)
    }

    func restoreAll() {
        stopRecording()
        // Remove the page's old assignments first, so swapped keys can be restored.
        for target in Self.targets {
            write(nil, to: target)
        }
        shortcuts.reload()
        errors = [:]
        for target in Self.targets {
            restore(target)
        }
    }

    func useDefaults() {
        restoreAll()
        session?.advance()
    }

    func preset(_ replacement: OnboardingViewModel.ExternalKeyboardShortcutReplacement?) {
        stopRecording()
        let store = shortcuts.settingsStore
        let activation = replacement?.activationHotkey ?? .defaultActivation
        let ask = replacement?.askHotkey ?? .defaultAsk
        let followsPreset = store.auxiliaryHotkey.map { binding in
            [63, 54, 61].contains { HotkeyBinding.auxiliaryChord(baseKeyCode: $0).conflicts(with: binding) }
        } ?? false
        let auxiliary = followsPreset ? HotkeyBinding.auxiliaryChord(baseKeyCode: activation.keyCode) : store
            .auxiliaryHotkey
        var assignments = store.hotkeyAssignments
        assignments[.builtIn(.activation)] = activation
        assignments[.builtIn(.ask)] = ask
        assignments[.builtIn(.auxiliary)] = auxiliary
        for target in [HotkeyTarget.builtIn(.activation), .builtIn(.ask), .builtIn(.auxiliary)] {
            if let candidate = assignments[target],
               let problem = HotkeyConflictChecker.check(candidate, for: target, among: assignments).problem {
                errors[.builtIn(.activation)] = describe(problem)
                return
            }
        }
        if let replacement {
            session?.useExternalKeyboardShortcutReplacement(replacement)
        } else {
            session?.restoreDefaultFNShortcuts()
        }
        session?.showShortcutReplacementAppliedAlert = false
        errors = [:]
        refresh()
    }

    func menuActions(_ target: HotkeyTarget) -> [TFMenuAction] {
        var actions: [TFMenuAction] = []
        if target == .builtIn(.activation) {
            actions = [
                .toggle("fn",
                        isOn: binding(target)?.signature == HotkeyBinding.defaultActivation
                            .signature) { [weak self] _ in self?.preset(nil) },
                .toggle(
                    Self.text("rightCommand"),
                    isOn: binding(target)?.signature == HotkeyBinding.rightCommandActivation.signature
                ) { [weak self] _ in
                    self?.preset(.rightCommand)
                },
                .toggle(
                    Self.text("rightOption"),
                    isOn: binding(target)?.signature == HotkeyBinding.rightOptionActivation.signature
                ) { [weak self] _ in
                    self?.preset(.rightOption)
                },
                .separator
            ]
        }
        return actions + [
            .action(Self.text("record")) { [weak self] in self?.startRecording(target) },
            .action(Self.text("reset")) { [weak self] in self?.restore(target) },
            .action(Self.text("clear")) { [weak self] in self?.apply(nil, to: target) }
        ]
    }

    var alternative: HotkeyBinding {
        HotkeyBinding(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    }

    var canOfferAlternative: Bool {
        guard let current = binding(.builtIn(.ask)), systemShortcuts.contains(current) else { return false }
        return shortcuts.check(alternative, for: .builtIn(.ask)).canSave && !systemShortcuts.contains(alternative)
    }

    func openGuide() {
        guideVisible = true
        openKeyboardSettings()
    }
}
