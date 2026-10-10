import Foundation

enum AskSystemCommand: String, CaseIterable, Sendable, Identifiable {
    case toggleBluetooth, toggleWiFi, ejectAllDisks, toggleHiddenFiles, toggleDesktopFiles
    case toggleDarkMode, resetTrackpadZoom, showTrash, emptyTrash, screenSaver
    case sleep, displaySleep, shutdown, restart, toggleScrollDirection, resetSpotlight, lockScreen, cleanScreen

    static let idPrefix = "system."
    var id: String {
        Self.idPrefix + rawValue
    }

    init?(pluginID: String) {
        guard pluginID.hasPrefix(Self.idPrefix) else { return nil }
        self.init(rawValue: String(pluginID.dropFirst(Self.idPrefix.count)))
    }

    var title: String {
        L("ask.system." + rawValue)
    }

    var searchNames: [String] {
        let aliases: [String] = switch self {
        case .toggleWiFi: ["WiFi", "无线网络"]
        case .restart: ["重启"]
        case .screenSaver: ["屏保"]
        case .lockScreen: ["锁屏"]
        default: []
        }
        return [englishTitle, chineseTitle] + aliases
    }

    var confirmationMessage: String {
        switch self {
        case .emptyTrash, .shutdown, .restart, .resetSpotlight:
            L("ask.system.confirm." + rawValue)
        default:
            L("ask.system.confirm", title)
        }
    }

    var symbol: String {
        switch self {
        case .toggleBluetooth: "antenna.radiowaves.left.and.right"
        case .toggleWiFi: "wifi"
        case .ejectAllDisks: "eject.fill"
        case .toggleHiddenFiles: "eye"
        case .toggleDesktopFiles: "desktopcomputer"
        case .toggleDarkMode: "moon.fill"
        case .resetTrackpadZoom: "arrow.down.right.and.arrow.up.left"
        case .showTrash, .emptyTrash: "trash"
        case .screenSaver: "sparkles.tv"
        case .sleep: "moon.zzz.fill"
        case .displaySleep: "display"
        case .shutdown: "power"
        case .restart: "arrow.clockwise"
        case .toggleScrollDirection: "arrow.up.arrow.down"
        case .resetSpotlight: "magnifyingglass"
        case .lockScreen: "lock.fill"
        case .cleanScreen: "hand.raised.fill"
        }
    }

    var englishTitle: String {
        switch self {
        case .toggleBluetooth: "Toggle Bluetooth"
        case .toggleWiFi: "Toggle Wi-Fi"
        case .ejectAllDisks: "Eject All Disks"
        case .toggleHiddenFiles: "Show/Hide Hidden Files"
        case .toggleDesktopFiles: "Hide/Show Desktop Files"
        case .toggleDarkMode: "Toggle Dark Mode"
        case .resetTrackpadZoom: "Reset Trackpad Zoom"
        case .showTrash: "Show Trash"
        case .emptyTrash: "Empty Trash"
        case .screenSaver: "Activate Screen Saver"
        case .sleep: "Enter Sleep"
        case .displaySleep: "Display Sleep"
        case .shutdown: "Shutdown"
        case .restart: "Restart"
        case .toggleScrollDirection: "Toggle Scroll Direction"
        case .resetSpotlight: "Reset Spotlight Index"
        case .lockScreen: "Lock Screen"
        case .cleanScreen: "Clean Screen & Keyboard"
        }
    }

    /// Full English command name without separators, suitable for the launcher prefix.
    var defaultKeyword: String {
        englishTitle.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var chineseTitle: String {
        switch self {
        case .toggleBluetooth: "切换蓝牙"
        case .toggleWiFi: "切换 Wi-Fi"
        case .ejectAllDisks: "推出所有磁盘"
        case .toggleHiddenFiles: "显示或隐藏隐藏文件"
        case .toggleDesktopFiles: "显示或隐藏桌面文件"
        case .toggleDarkMode: "切换深色模式"
        case .resetTrackpadZoom: "重置触控板缩放"
        case .showTrash: "打开废纸篓"
        case .emptyTrash: "清空废纸篓"
        case .screenSaver: "启动屏幕保护程序"
        case .sleep: "进入睡眠"
        case .displaySleep: "关闭显示器"
        case .shutdown: "关机"
        case .restart: "重新启动"
        case .toggleScrollDirection: "切换滚动方向"
        case .resetSpotlight: "重建 Spotlight 索引"
        case .lockScreen: "锁定屏幕"
        case .cleanScreen: "清洁屏幕和键盘"
        }
    }
}

struct AskSystemCommandPlugin: AskLauncherPlugin {
    var command: AskSystemCommand
    var id: String {
        command.id
    }

    var title: String {
        command.title
    }

    var symbol: String {
        command.symbol
    }

    var defaultKeywords: [AskKeyword] {
        []
    }

    var runsWithoutInput: Bool {
        true
    }

    var usesSelectionInput: Bool {
        false
    }

    var entersOnReturn: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        title
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        .init(mode: .onSubmit, title: title, actions: [
            .init(kind: .systemCommand(command), title: L("ask.system.run"), symbol: symbol, shortcut: .enter)
        ])
    }

    func run(_: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // The model dispatches the plan's action after explicit submission.
        throw AskPluginFailure(message: L("ask.system.failed"), retry: false)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}
