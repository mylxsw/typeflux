import AppKit
import SwiftUI

/// The apps behind "More". A search field appears once the list is long.
struct RingHiddenAppsList: View {
    static let searchThreshold = 6

    let profiles: [RingAppProfile]
    var onPick: (RingAppProfile) -> Void

    @State private var query = ""

    static func filtered(_ profiles: [RingAppProfile], query: String) -> [RingAppProfile] {
        profiles.filter { TFSearchMatcher.matches(query, $0.appName, $0.bundleIdentifier) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if profiles.count > Self.searchThreshold {
                TFSearchField(placeholder: L("ring.scope.searchApps"), text: $query, placement: .container,
                              focusOnAppear: true, onSubmit: {
                                  if let first = Self.filtered(profiles, query: query).first {
                                      onPick(first)
                                  }
                              }, identifier: "ring.scope.more.search")
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: 0) {
                    let rows = Self.filtered(profiles, query: query)
                    ForEach(rows) { profile in
                        Button { onPick(profile) } label: {
                            RingAppRow(bundleIdentifier: profile.bundleIdentifier, name: profile.appName,
                                       subtitle: nil, isDimmed: !profile.isEnabled) {
                                Text(profile.isEnabled ? L("ring.scope.actionCount", profile.actions.count)
                                    : L("ring.scope.disabled"))
                                    .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ring.scope.more.\(profile.bundleIdentifier)")
                    }
                    if rows.isEmpty {
                        Text(L("ring.library.noResults")).font(.system(size: 12.5))
                            .foregroundStyle(TFColors.textSecondary).padding(.vertical, 20)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(8)
        .frame(width: 280)
    }
}

/// Picks an app to give its own actions: running apps first, then the rest.
struct RingAddAppPicker: View {
    let apps: [RingLibraryApp]
    let isLoading: Bool
    let configured: Set<String>
    let running: Set<String>
    var onPick: (_ bundleIdentifier: String, _ name: String) -> Void
    var onChooseOther: () -> Void

    @State private var query = ""

    /// Running apps first, both groups keeping their order; matching name or bundle identifier.
    static func groups(_ apps: [RingLibraryApp], running: Set<String>,
                       query: String) -> (running: [RingLibraryApp], others: [RingLibraryApp]) {
        let matches = apps.filter { TFSearchMatcher.matches(query, $0.name, $0.bundleIdentifier) }
        return (matches.filter { running.contains($0.bundleIdentifier) },
                matches.filter { !running.contains($0.bundleIdentifier) })
    }

    var body: some View {
        let groups = Self.groups(apps, running: running, query: query)
        VStack(spacing: 0) {
            TFSearchField(placeholder: L("ring.scope.searchApps"), text: $query, placement: .container,
                          focusOnAppear: true, onSubmit: submitFirst, identifier: "ring.scope.add.search")
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading, apps.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    section(L("ring.scope.running"), groups.running)
                    section(L("ring.scope.otherApps"), groups.others)
                    if !isLoading, groups.running.isEmpty, groups.others.isEmpty {
                        Text(L("ring.library.noResults")).font(.system(size: 12.5))
                            .foregroundStyle(TFColors.textSecondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
            }
            .frame(height: 300)
            Divider().padding(.vertical, 4)
            Button(action: onChooseOther) {
                Label(L("ring.scope.chooseOther"), systemImage: "folder")
                    .font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ring.scope.add.other")
        }
        .padding(8)
        .frame(width: 320)
    }

    @ViewBuilder private func section(_ title: String, _ apps: [RingLibraryApp]) -> some View {
        if !apps.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(TFColors.textTertiary)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            ForEach(apps, id: \.bundleIdentifier) { app in
                let done = configured.contains(app.bundleIdentifier)
                Button { onPick(app.bundleIdentifier, app.name) } label: {
                    RingAppRow(bundleIdentifier: app.bundleIdentifier, name: app.name,
                               subtitle: app.bundleIdentifier, isDimmed: done) {
                        if done {
                            Label(L("ring.scope.configured"), systemImage: "checkmark")
                                .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                        } else if running.contains(app.bundleIdentifier) {
                            Circle().fill(TFColors.success).frame(width: 6, height: 6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(done)
                .accessibilityIdentifier("ring.scope.add.\(app.bundleIdentifier)")
            }
        }
    }

    private func submitFirst() {
        let groups = Self.groups(apps, running: running, query: query)
        if let first = (groups.running + groups.others).first(where: { !configured.contains($0.bundleIdentifier) }) {
            onPick(first.bundleIdentifier, first.name)
        }
    }
}

/// One app in a list: icon, name, optional bundle identifier and a trailing accessory.
struct RingAppRow<Accessory: View>: View {
    let bundleIdentifier: String
    let name: String
    let subtitle: String?
    let isDimmed: Bool
    @ViewBuilder var accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: RingAppIcon.image(bundleIdentifier: bundleIdentifier)).resizable()
                .interpolation(.high).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13)).foregroundStyle(TFColors.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TFColors.textTertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .opacity(isDimmed ? 0.5 : 1)
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering && !isDimmed ? TFColors.selection : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Under the tabs: what the selected scope is, with its switch and menu.
struct RingScopeInfoBar: View {
    let profile: RingAppProfile?
    let hasOtherProfiles: Bool
    let canReset: Bool
    let canCopyGlobal: Bool
    var onReset: () -> Void = {}
    var onEnable: (Bool) -> Void = { _ in }
    var onCopyGlobal: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if let profile {
                Image(nsImage: RingAppIcon.image(bundleIdentifier: profile.bundleIdentifier)).resizable()
                    .interpolation(.high).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.appName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TFColors.textPrimary)
                    if RingAppIcon.isInstalled(profile.bundleIdentifier) {
                        Text(profile.bundleIdentifier).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TFColors.textTertiary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Label(L("ring.scope.appMissing"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(TFColors.warning)
                    }
                }
                Spacer(minLength: 8)
                Text(L("ring.scope.enabled")).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                Toggle("", isOn: Binding(get: { profile.isEnabled }, set: onEnable))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L("ring.scope.enabledAccessibility", profile.appName))
                    .accessibilityIdentifier("ring.scope.enabled")
                Menu {
                    Button(L("ring.scope.copyGlobal"), action: onCopyGlobal).disabled(!canCopyGlobal)
                    Divider()
                    Button(L("ring.scope.delete", profile.appName), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("ring.scope.menu"))
                .accessibilityIdentifier("ring.scope.menu")
            } else {
                Image(systemName: "globe").font(.system(size: 14, weight: .medium)).foregroundStyle(TFColors.accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TFColors.selection))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ring.scope.globalTitle")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TFColors.textPrimary)
                    Text(L(hasOtherProfiles ? "ring.scope.otherApps.subtitle" : "ring.scope.allApps"))
                        .font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                }
                Spacer(minLength: 8)
                TFButton(title: L("ring.actions.reset"), systemImage: "arrow.counterclockwise", kind: .plain,
                         size: .small, action: onReset)
                    .disabled(!canReset)
                    .accessibilityIdentifier("ring.actions.reset")
            }
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 50)
    }
}
