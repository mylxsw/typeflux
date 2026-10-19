import AppKit
import SwiftUI

/// Settings › Appearance › Voice input capsule: the capsule style plus the options that apply to it.
struct VoiceCapsuleSettingsSection: View {
    @Binding var preferences: VoiceCapsulePreferences
    /// Whether any connected display has a camera housing; decides the "This Mac" badge.
    var hasNotchedDisplay: Bool = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }

    var body: some View {
        TFFormSection(title: L("voiceCapsule.settings.title"), footnote: L("voiceCapsule.settings.footnote")) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(VoiceCapsuleStyle.allCases, id: \.self) { style in
                    TFChoiceCard(title: style.displayName, isSelected: preferences.style == style) {
                        preferences.style = style
                    } preview: {
                        VoiceCapsuleStylePreview(style: style, showsBadge: style == .notchIsland && hasNotchedDisplay)
                    }
                    .accessibilityHint(style.detail)
                    .accessibilityIdentifier("settings.voiceCapsule.style." + style.rawValue)
                }
            }
            .padding(14)
            TFDivider.form
            TFFormRow(title: L("voiceCapsule.livePreview.title"), detail: L("voiceCapsule.livePreview.detail")) {
                TFSwitch(title: L("voiceCapsule.livePreview.title"), isOn: $preferences.showsLivePreview)
            }
            TFDivider.form
            TFFormRow(title: L("voiceCapsule.screen.title"), detail: L("voiceCapsule.screen.detail")) {
                TFPopUpButton(
                    title: L("voiceCapsule.screen.title"),
                    options: VoiceCapsuleScreenChoice.allCases.map { TFOption($0, $0.displayName) },
                    selection: $preferences.screen,
                    width: TFMetrics.formControlWidth,
                    identifier: "settings.voiceCapsule.screen"
                )
            }
            if preferences.style == .cornerCard {
                TFDivider.form
                TFFormRow(title: L("voiceCapsule.corner.title"), detail: L("voiceCapsule.corner.detail")) {
                    TFSegmentedControl(
                        options: VoiceCapsuleCornerEdge.allCases.map { TFOption($0, $0.displayName) },
                        selection: $preferences.cornerEdge,
                        identifier: { "settings.voiceCapsule.corner." + $0.rawValue }
                    )
                }
                TFDivider.form
                TFFormRow(title: L("voiceCapsule.showContext.title"), detail: L("voiceCapsule.showContext.detail")) {
                    TFSwitch(title: L("voiceCapsule.showContext.title"), isOn: $preferences.showsTargetApp)
                }
            }
            if preferences.style == .notchIsland {
                TFDivider.form
                TFFormRow(title: L("voiceCapsule.notchFallback.title"), detail: L("voiceCapsule.notchFallback.detail")) {
                    TFPopUpButton(
                        title: L("voiceCapsule.notchFallback.title"),
                        options: VoiceCapsuleNotchFallback.allCases.map { TFOption($0, $0.displayName) },
                        selection: $preferences.notchFallback,
                        width: TFMetrics.formControlWidth,
                        identifier: "settings.voiceCapsule.notchFallback"
                    )
                }
                TFDivider.form
                TFFormRow(title: L("voiceCapsule.hoverExpand.title"), detail: L("voiceCapsule.hoverExpand.detail")) {
                    TFSwitch(title: L("voiceCapsule.hoverExpand.title"), isOn: $preferences.notchHoverExpands)
                }
            }
        }
    }
}

/// A small schematic screen showing where each style appears.
struct VoiceCapsuleStylePreview: View {
    let style: VoiceCapsuleStyle
    var showsBadge = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.95).opacity(0.55),
                                    Color(red: 0.86, green: 0.62, blue: 0.86).opacity(0.45)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            Rectangle().fill(Color.white.opacity(0.28)).frame(height: 9)
            RoundedRectangle(cornerRadius: 3).fill(StudioTheme.surface.opacity(0.8))
                .frame(width: 88, height: 50)
                .padding(.top, 28)
            capsule
            if showsBadge {
                HStack {
                    Spacer()
                    TFTag(text: L("voiceCapsule.notch.thisMac"), tint: TFColors.success)
                }
                .padding(.top, 14)
                .padding(.trailing, 6)
            }
        }
        // Four cards share the row, so the screen narrows before the cards overflow.
        .frame(minWidth: 112, maxWidth: 160)
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.border) }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var capsule: some View {
        switch style {
        case .bottomCapsule:
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                    .frame(width: 34, height: 11)
                    .overlay { waveform }
                    .shadow(color: Color.black.opacity(0.25), radius: 3, y: 2)
                    .padding(.bottom, 8)
            }
        case .orbCapsule:
            VStack {
                Spacer()
                miniCapsule(width: 34, height: 11, radius: 5.5)
                    .padding(.bottom, 8)
            }
        case .cornerCard:
            HStack {
                Spacer()
                miniCapsule(width: 62, height: 16, radius: 8)
                    .padding(.trailing, 6)
            }
            .padding(.top, 12)
        case .notchIsland:
            NotchIslandShape(bottomRadius: 5, fillet: 3)
                .fill(Color.black)
                .frame(width: 70, height: 12)
                .overlay(alignment: .leading) {
                    orbDot.padding(.leading, 9)
                }
        }
    }

    private func miniCapsule(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
            .frame(width: width, height: height)
            .overlay(alignment: .leading) { orbDot.padding(.leading, height / 2 - 2.5) }
            .shadow(color: Color.black.opacity(0.25), radius: 3, y: 2)
    }

    /// The original capsule's level bars.
    private var waveform: some View {
        HStack(spacing: 1.5) {
            ForEach([2.5, 4.5, 6, 4, 2.5], id: \.self) { height in
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 1.5, height: height)
            }
        }
    }

    private var orbDot: some View {
        Circle()
            .fill(AngularGradient(colors: [.blue, .purple, .pink, .cyan, .blue], center: .center))
            .frame(width: 5, height: 5)
    }
}
