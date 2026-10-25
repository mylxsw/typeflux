import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App icons by bundle identifier, with the generic app icon for apps that are not installed.
@MainActor
enum RingAppIcon {
    private static var cache: [String: NSImage] = [:]

    static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func image(bundleIdentifier: String) -> NSImage {
        if let cached = cache[bundleIdentifier] {
            return cached
        }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[bundleIdentifier] = image
        return image
    }
}

/// Which app tabs fit in one row. The row never scrolls sideways (many mice cannot): the rest go
/// behind "More", and the selected app always keeps a visible place.
enum RingScopeBarLayout {
    static let spacing: CGFloat = 6

    /// Indexes of the tabs shown, in order. `reserved` is the width of everything that is always
    /// there (the global tab, the divider and "Add App").
    static func visibleIndexes(chipWidths: [CGFloat], available: CGFloat, reserved: CGFloat, moreWidth: CGFloat,
                               selected: Int?) -> [Int] {
        var used = reserved
        var fit = 0
        for (index, width) in chipWidths.enumerated() {
            used += width + spacing
            let needsMore = index < chipWidths.count - 1
            if used + (needsMore ? moreWidth + spacing : 0) > available {
                break
            }
            fit = index + 1
        }
        var visible = Array(0 ..< fit)
        if let selected, chipWidths.indices.contains(selected), selected >= fit {
            // The selected tab takes the last visible place; the one it replaces goes behind "More".
            if visible.isEmpty {
                visible = [selected]
            } else {
                visible[visible.count - 1] = selected
            }
        }
        return visible
    }

    /// The width of a tab: icon, title and a short detail such as the action count.
    static func chipWidth(title: String, detail: String) -> CGFloat {
        func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
                .width)
        }
        return 5 + 22 + 7 + width(title, 12.5, .semibold) + 7 + width(detail, 11, .medium) + 12
    }
}

/// The row above Ring Studio: "Global", the apps with their own actions, "More" and "Add App".
struct RingScopeBar: View {
    let profiles: [RingAppProfile]
    let globalCount: Int
    let scope: RingSettingsScope
    let apps: [RingLibraryApp]
    let isLoadingApps: Bool
    var onSelect: (RingSettingsScope) -> Void = { _ in }
    var onAdd: (_ bundleIdentifier: String, _ name: String) -> Void = { _, _ in }
    var onOpenPicker: () -> Void = {}

    @State private var showsMore = false
    @State private var showsPicker = false

    static let height: CGFloat = 52

    private var selectedIndex: Int? {
        guard case let .app(id) = scope else { return nil }
        return profiles.firstIndex { $0.id == id }
    }

    var body: some View {
        GeometryReader { geometry in
            let visible = visibleIndexes(width: geometry.size.width - 24)
            let hidden = profiles.indices.filter { !visible.contains($0) }
            HStack(spacing: RingScopeBarLayout.spacing) {
                globalChip
                if !profiles.isEmpty {
                    Rectangle().fill(TFColors.border).frame(width: 0.5, height: 18).padding(.horizontal, 2)
                }
                ForEach(visible, id: \.self) { index in
                    appChip(profiles[index])
                }
                if !hidden.isEmpty {
                    moreButton(hidden.map { profiles[$0] })
                }
                Spacer(minLength: 0)
                addButton
            }
            .padding(.horizontal, 12)
            .frame(width: geometry.size.width, height: Self.height)
        }
        .frame(height: Self.height)
    }

    private func visibleIndexes(width: CGFloat) -> [Int] {
        let widths = profiles.map { RingScopeBarLayout.chipWidth(title: $0.appName, detail: Self.detail(of: $0)) }
        let reserved = RingScopeBarLayout.chipWidth(title: L("ring.scope.global"), detail: "\(globalCount)")
            + RingScopeBarLayout.spacing + 5 + RingScopeBarLayout.spacing + Self
            .addWidth(hasProfiles: !profiles.isEmpty)
        let more = RingScopeBarLayout.chipWidth(title: L("ring.scope.more"), detail: "\(profiles.count)") + 10
        return RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: width, reserved: reserved,
                                                 moreWidth: more, selected: selectedIndex)
    }

    static func detail(of profile: RingAppProfile) -> String {
        profile.isEnabled ? "\(profile.actions.count)" : L("ring.scope.disabled")
    }

    private static func addWidth(hasProfiles: Bool) -> CGFloat {
        let title = L(hasProfiles ? "ring.scope.addApp" : "ring.scope.addFirstApp")
        return ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5,
                                                                                       weight: .medium)]).width) + 40
    }

    // MARK: - Tabs

    private var globalChip: some View {
        Button { onSelect(.global) } label: {
            RingScopeChipLabel(isSelected: scope == .global, isDimmed: false, hasIssue: false,
                               title: L("ring.scope.global"), detail: "\(globalCount)") {
                Image(systemName: "globe").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(scope == .global ? Color.white : TFColors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(scope == .global ? TFColors.accent : TFColors.control))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ring.scope.global")
    }

    private func appChip(_ profile: RingAppProfile) -> some View {
        let selected = scope == .app(profile.id)
        return Button { onSelect(.app(profile.id)) } label: {
            RingScopeChipLabel(isSelected: selected, isDimmed: !profile.isEnabled,
                               hasIssue: !RingAppIcon.isInstalled(profile.bundleIdentifier),
                               title: profile.appName, detail: Self.detail(of: profile)) {
                Image(nsImage: RingAppIcon.image(bundleIdentifier: profile.bundleIdentifier))
                    .resizable().interpolation(.high).frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help(profile.appName)
        .accessibilityIdentifier("ring.scope.app.\(profile.bundleIdentifier)")
    }

    private func moreButton(_ hidden: [RingAppProfile]) -> some View {
        let holdsSelection = hidden.contains { scope == .app($0.id) }
        return Button { showsMore.toggle() } label: {
            HStack(spacing: 5) {
                Text(L("ring.scope.more")).font(.system(size: 12.5, weight: .medium))
                Text("\(hidden.count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(TFColors.textTertiary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showsMore ? 180 : 0))
            }
            .foregroundStyle(holdsSelection ? TFColors.accent : TFColors.textPrimary)
            .padding(.leading, 12).padding(.trailing, 10).frame(height: 32)
            .background(Capsule().fill(holdsSelection ? TFColors.selection : TFColors.control))
            .overlay(Capsule().strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ring.scope.moreAccessibility", hidden.count))
        .accessibilityIdentifier("ring.scope.more")
        .popover(isPresented: $showsMore, arrowEdge: .bottom) {
            RingHiddenAppsList(profiles: hidden) { profile in
                showsMore = false
                onSelect(.app(profile.id))
            }
        }
    }

    private var addButton: some View {
        Button {
            onOpenPicker()
            showsPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .bold))
                Text(L(profiles.isEmpty ? "ring.scope.addFirstApp" : "ring.scope.addApp"))
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(TFColors.accent)
            .padding(.horizontal, 12).frame(height: 32)
            .overlay(Capsule().strokeBorder(TFColors.accent.opacity(0.55),
                                            style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ring.scope.add")
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            RingAddAppPicker(apps: apps, isLoading: isLoadingApps,
                             configured: Set(profiles.map(\.bundleIdentifier)),
                             running: Self.runningBundleIdentifiers()) { bundleIdentifier, name in
                showsPicker = false
                onAdd(bundleIdentifier, name)
            } onChooseOther: {
                showsPicker = false
                Self.chooseApplication(onAdd)
            }
        }
    }

    static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
    }

    /// Any app in a Finder panel, for apps the list does not show.
    private static func chooseApplication(_ onAdd: @escaping (String, String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        onAdd(bundleIdentifier, name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}

/// A tab: icon, title and detail in a capsule.
struct RingScopeChipLabel<Icon: View>: View {
    let isSelected: Bool
    let isDimmed: Bool
    let hasIssue: Bool
    let title: String
    let detail: String
    @ViewBuilder var icon: Icon
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            icon.opacity(isDimmed ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if hasIssue {
                        Circle().fill(TFColors.warning).frame(width: 7, height: 7).offset(x: 2, y: -1)
                    }
                }
            Text(title).font(.system(size: 12.5, weight: isSelected ? .semibold : .medium)).lineLimit(1)
                .opacity(isDimmed ? 0.55 : 1)
            Text(detail).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(isSelected ? TFColors.accent.opacity(0.8) : TFColors.textTertiary)
        }
        .foregroundStyle(isSelected ? TFColors.accent : TFColors.textPrimary)
        .padding(.leading, 5).padding(.trailing, 12).frame(height: 32)
        .background(Capsule().fill(isSelected ? TFColors.selection : TFColors.control))
        .overlay(Capsule().fill(hovering && !isSelected ? TFColors.hoverOverlay : .clear))
        .overlay(Capsule().strokeBorder(isSelected ? TFColors.accent : TFColors.border,
                                        lineWidth: isSelected ? 1 : TFMetrics.borderWidth))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}
