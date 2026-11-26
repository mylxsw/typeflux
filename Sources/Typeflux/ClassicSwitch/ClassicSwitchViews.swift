import AppKit
import SwiftUI

/// Features that exist in Typeflux but not in Typeflux Classic.
enum ClassicFeatureComparison {
    struct Feature: Identifiable, Equatable {
        let id: String
        let symbol: String
        var title: String { L("classic.feature.\(id)") }
    }

    static let voiceInput = Feature(id: "voice", symbol: "waveform")
    static let missingInClassic: [Feature] = [
        Feature(id: "launcher", symbol: "magnifyingglass"),
        Feature(id: "chat", symbol: "bubble.left.and.bubble.right"),
        Feature(id: "ring", symbol: "circle.dashed"),
        Feature(id: "screenshot", symbol: "camera.viewfinder"),
        Feature(id: "clipboard", symbol: "doc.on.clipboard"),
    ]
}

private enum ClassicDialogMetrics {
    static let padding: CGFloat = 24
    static let spacing: CGFloat = 18
    static let iconSize: CGFloat = 52
}

private struct ClassicAppIcon: View {
    var body: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: ClassicDialogMetrics.iconSize, height: ClassicDialogMetrics.iconSize)
        }
    }
}

// MARK: - Introduction

struct ClassicIntroView: View {
    let canSwitch: Bool
    let onContinue: () -> Void
    let onSwitch: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ClassicDialogMetrics.spacing) {
            HStack(spacing: 14) {
                ClassicAppIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("classic.intro.title"))
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    Text(L("classic.intro.subtitle"))
                        .font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            comparisonTable
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: L("classic.intro.learnMore"), systemImage: "arrow.up.right", kind: .link, action: onLearnMore)
                    .accessibilityIdentifier("classic.intro.learnMore")
                Spacer(minLength: 12)
                if canSwitch {
                    TFButton(title: L("classic.action.switch"), action: onSwitch)
                        .accessibilityIdentifier("classic.intro.switch")
                }
                TFButton(title: L("classic.intro.continue"), kind: .primary, action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("classic.intro.continue")
            }
        }
        .padding(ClassicDialogMetrics.padding)
        .frame(width: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classic.intro")
    }

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            row(title: nil, symbol: nil, typeflux: .header("Typeflux"), classic: .header("Typeflux Classic"))
            divider
            row(title: ClassicFeatureComparison.voiceInput.title, symbol: ClassicFeatureComparison.voiceInput.symbol,
                typeflux: .included, classic: .included)
            ForEach(ClassicFeatureComparison.missingInClassic) { feature in
                divider
                row(title: feature.title, symbol: feature.symbol, typeflux: .included, classic: .missing)
            }
            divider
            row(title: L("classic.feature.account"), symbol: "person.crop.circle", typeflux: .included, classic: .included)
        }
        .background(TFColors.card, in: RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
            .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }

    private enum Cell { case header(String), included, missing }

    private var divider: some View {
        Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth)
    }

    private func row(title: String?, symbol: String?, typeflux: Cell, classic: Cell) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TFColors.textSecondary).frame(width: 18)
                }
                if let title {
                    Text(title).font(.system(size: 13)).foregroundStyle(TFColors.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(typeflux).frame(width: 140)
            cell(classic).frame(width: 140)
        }
        .padding(.horizontal, TFMetrics.rowHorizontalPadding)
        .frame(height: title == nil ? 34 : 32)
    }

    @ViewBuilder
    private func cell(_ cell: Cell) -> some View {
        switch cell {
        case let .header(name):
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
        case .included:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.accent)
                .accessibilityLabel(L("classic.feature.included"))
        case .missing:
            Image(systemName: "minus").font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.textTertiary)
                .accessibilityLabel(L("classic.feature.notIncluded"))
        }
    }
}

// MARK: - Switch flow

struct ClassicSwitchView: View {
    @ObservedObject var controller: ClassicSwitchController

    var body: some View {
        VStack(alignment: .leading, spacing: ClassicDialogMetrics.spacing) {
            content
        }
        .padding(ClassicDialogMetrics.padding)
        .frame(width: 440, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classic.switch")
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .confirming:
            confirmation
        case let .downloading(fraction):
            header(L("classic.switch.downloading"))
            progress(fraction)
            buttons {
                TFButton(title: L("common.cancel")) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("classic.switch.cancel")
            }
        case .installing:
            header(L("classic.switch.installing"))
            ProgressView().progressViewStyle(.linear)
        case let .failed(message):
            header(L("classic.switch.failed"))
            Text(message)
                .font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("classic.switch.error")
            buttons {
                TFButton(title: L("common.cancel")) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                TFButton(title: L("common.retry"), kind: .primary) { controller.retry() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("classic.switch.retry")
            }
        }
    }

    @ViewBuilder
    private var confirmation: some View {
        header(L("classic.switch.confirm.title"))
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TFColors.success)
            Text(L("classic.switch.confirm.dataKept"))
                .font(.system(size: 13)).foregroundStyle(TFColors.textPrimary)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(L("classic.switch.confirm.missing"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(ClassicFeatureComparison.missingInClassic) { feature in
                    Label(feature.title, systemImage: feature.symbol)
                        .font(.system(size: 13)).foregroundStyle(TFColors.textPrimary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColors.card, in: RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
            .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        buttons {
            TFButton(title: L("common.cancel")) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            TFButton(title: L("classic.switch.confirm.action"), kind: .primary) { controller.confirm() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("classic.switch.confirm")
        }
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 14) {
            ClassicAppIcon()
            Text(title)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ fraction: Double?) -> some View {
        HStack(spacing: 12) {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(TFColors.textSecondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .accessibilityIdentifier("classic.switch.progress")
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            Spacer()
            content()
        }
    }
}

// MARK: - Entry rows

/// Wraps a switch entry point. The content, including any row chrome, only exists while a
/// published Classic is available, so a hidden entry leaves no gap in its container.
struct ClassicSwitchEntry<Content: View>: View {
    @ObservedObject var controller: ClassicSwitchController
    @ViewBuilder let content: () -> Content

    var body: some View {
        if controller.isAvailable {
            content()
        }
    }
}

extension View {
    /// Re-checks Classic availability (cached for a while) when the containing page appears.
    @MainActor
    func refreshesClassicAvailability(_ controller: ClassicSwitchController? = nil) -> some View {
        let controller = controller ?? .shared
        return task { await controller.refreshAvailability() }
    }
}
