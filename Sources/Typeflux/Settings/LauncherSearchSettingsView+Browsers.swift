import AppKit
import SwiftUI

extension LauncherSearchSettingsView {
    var browsersTab: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            browserSection(kind: .tab)
            browserSection(kind: .bookmark)
            TFFormSection(title: L("ask.browser.permissions"), footnote: L("ask.browser.permissionHint")) {
                TFActionRow(systemImage: "lock.shield", title: L("ask.browser.automationSettings")) {
                    NSWorkspace.shared
                        .open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                        )
                }
                TFDivider.formWithIcon
                TFActionRow(systemImage: "lock.open", title: L("launcher.search.fda.open")) {
                    NSWorkspace.shared.open(AskFullDiskAccess.settingsURL)
                }
            }
        }
        .accessibilityIdentifier("launcher.search.browsers")
    }

    private func browserSection(kind: AskBrowserSearchEntry.Kind) -> some View {
        let tabs = kind == .tab
        let enabled = tabs ? browserPreferences.tabsEnabled : browserPreferences.bookmarksEnabled
        return TFFormSection(title: L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"),
                             footnote: L(tabs ? "ask.browser.tabsHint" : "ask.browser.bookmarksHint")) {
            TFFormRow(title: L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"), detail: tabs ? "tab" : "bmk",
                      icon: tabs ? "rectangle.on.rectangle" : "bookmark") {
                TFSwitch(title: L(tabs ? "ask.browser.tabs" : "ask.browser.bookmarks"),
                         isOn: browserBinding(tabs ? \.tabsEnabled : \.bookmarksEnabled))
                    .accessibilityIdentifier("launcher.search.browser.\(kind.rawValue).enabled")
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ask.browser.direct"), detail: L("ask.browser.directHint"), icon: "magnifyingglass") {
                TFSwitch(title: L("ask.browser.direct"), isOn: browserBinding(tabs ? \.directTabs : \.directBookmarks))
                    .disabled(!enabled)
            }
            ForEach(AskSearchBrowser.allCases) { browser in
                TFDivider.formWithIcon
                TFFormRow(title: browser.title, icon: "globe") {
                    TFSwitch(title: browser.title, isOn: Binding(get: {
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
                    .disabled(!enabled)
                    .accessibilityIdentifier("launcher.search.browser.\(kind.rawValue).\(browser.id)")
                }
            }
            if !tabs {
                TFDivider.formWithIcon
                bookmarkBrowserRow.disabled(!enabled)
            }
        }
    }

    private var bookmarkBrowserRow: some View {
        TFFormRow(title: L("ask.browser.openWith"), icon: "arrow.up.forward.app") {
            TFPopUpButton(title: L("ask.browser.openWith"), options: [
                TFOption("", L("ask.browser.sourceBrowser")),
                TFOption("default", L("ask.browser.defaultBrowser"))
            ] + AskSearchBrowser.allCases.map { TFOption($0.rawValue, $0.title) },
            selection: browserBinding(\.bookmarkBrowser), width: TFMetrics.formControlWidth)
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
