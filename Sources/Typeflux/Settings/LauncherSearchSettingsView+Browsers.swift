import AppKit
import SwiftUI

extension LauncherSearchSettingsView {
    var browsersTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            browserSection(kind: .tab)
            browserSection(kind: .bookmark)
            AgentSettingsSection(title: L("ask.browser.permissions"), footnote: L("ask.browser.permissionHint")) {
                AgentSettingsActionRow(icon: "lock.shield", title: L("ask.browser.automationSettings")) {
                    NSWorkspace.shared
                        .open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                        )
                }
                ModelRowDivider(leading: 66)
                AgentSettingsActionRow(icon: "lock.open", title: L("launcher.search.fda.open")) {
                    NSWorkspace.shared.open(AskFullDiskAccess.settingsURL)
                }
            }
        }
        .accessibilityIdentifier("launcher.search.browsers")
    }

    private func browserSection(kind: AskBrowserSearchEntry.Kind) -> some View {
        let tabs = kind == .tab
        let enabled = tabs ? browserPreferences.tabsEnabled : browserPreferences.bookmarksEnabled
        return AgentSettingsSection(title: L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"),
                                    footnote: L(tabs ? "ask.browser.tabsHint" : "ask.browser.bookmarksHint")) {
            AgentSettingsRow(icon: tabs ? "rectangle.on.rectangle" : "bookmark",
                             title: L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"),
                             subtitle: tabs ? "tab" : "bmk") {
                Toggle("", isOn: browserBinding(tabs ? \.tabsEnabled : \.bookmarksEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"))
                    .accessibilityIdentifier("launcher.search.browser.\(kind.rawValue).enabled")
            }
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "magnifyingglass", title: L("ask.browser.direct"),
                             subtitle: L("ask.browser.directHint")) {
                Toggle("", isOn: browserBinding(tabs ? \.directTabs : \.directBookmarks))
                    .labelsHidden().toggleStyle(.switch).disabled(!enabled)
                    .accessibilityLabel(L("ask.browser.direct"))
            }
            ForEach(AskSearchBrowser.allCases) { browser in
                ModelRowDivider(leading: 66)
                AgentSettingsRow(icon: "globe", title: browser.title) {
                    Toggle("", isOn: Binding(get: {
                        (tabs ? browserPreferences.tabBrowsers : browserPreferences.bookmarkBrowsers).contains(browser)
                    }, set: { value in
                        updateBrowsers { preferences in
                            var selected = tabs ? preferences.tabBrowsers : preferences.bookmarkBrowsers
                            selected.removeAll { $0 == browser }
                            if value { selected.append(browser) }
                            if tabs {
                                preferences.tabBrowsers = selected
                            } else {
                                preferences.bookmarkBrowsers = selected
                            }
                        }
                    }))
                    .labelsHidden().toggleStyle(.switch).disabled(!enabled)
                    .accessibilityLabel(browser.title)
                    .accessibilityIdentifier("launcher.search.browser.\(kind.rawValue).\(browser.id)")
                }
            }
            if !tabs {
                ModelRowDivider(leading: 66)
                bookmarkBrowserRow.disabled(!enabled)
            }
        }
    }

    private var bookmarkBrowserRow: some View {
        AgentSettingsRow(icon: "arrow.up.forward.app", title: L("ask.browser.openWith")) {
            SettingsMenuPicker(title: L("ask.browser.openWith"), options: [
                (label: L("ask.browser.sourceBrowser"), value: ""),
                (label: L("ask.browser.defaultBrowser"), value: "default")
            ] + AskSearchBrowser.allCases.map { (label: $0.title, value: $0.rawValue) },
            selection: browserBinding(\.bookmarkBrowser))
                .frame(width: 180)
        }
    }

    private func browserBinding<Value>(_ path: WritableKeyPath<AskBrowserSearchSettings, Value>) -> Binding<Value> {
        Binding(
            get: { browserPreferences[keyPath: path] },
            set: { value in updateBrowsers { $0[keyPath: path] = value } }
        )
    }

    func updateBrowsers(_ change: (inout AskBrowserSearchSettings) -> Void) {
        var next = browserPreferences
        change(&next)
        guard next != browserPreferences else { return }
        browserPreferences = next
        settings.askBrowserSearchSettings = next
    }
}
