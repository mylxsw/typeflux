import SwiftUI

struct LiquidGlassIntensitySetting: View {
    @Binding var value: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        LiquidGlassIntensityControl(value: $value, accessibilityOverride: reduceTransparency || contrast == .increased)
    }
}

/// The environment adapter supplies the system accessibility policy to the control.
struct LiquidGlassIntensityControl: View {
    @Binding var value: Double
    let accessibilityOverride: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("settings.glassIntensity.title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(StudioTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    sliderControls.frame(minWidth: 220, maxWidth: .infinity)
                    preview
                }
                VStack(alignment: .leading, spacing: 10) {
                    sliderControls
                    preview.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if accessibilityOverride {
                Text(L("settings.glassIntensity.accessibility"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preview: some View {
        LiquidGlassIntensityPreview()
            .environment(\.liquidGlassIntensity, LiquidGlassIntensity(value))
    }

    private var sliderControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle").accessibilityHidden(true)
                Slider(value: $value, in: 0 ... 1)
                    .disabled(accessibilityOverride)
                    .accessibilityLabel(L("settings.glassIntensity.title"))
                    .accessibilityHint(L("settings.glassIntensity.subtitle"))
                    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("settings.liquidGlassIntensity.slider")
                Image(systemName: "rectangle.on.rectangle.fill").accessibilityHidden(true)
            }.foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Text(L("settings.glassIntensity.clear"))
                Spacer()
                Text(L("settings.glassIntensity.tinted"))
            }.font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
        }
    }
}

/// Real shared glass over an intentionally varied scene, so the preview changes
/// with the same material policy as the app's controls rather than a mock image.
struct LiquidGlassIntensityPreview: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.56, blue: 0.68),
                                    Color(red: 0.59, green: 0.69, blue: 0.65),
                                    Color(red: 0.72, green: 0.61, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 8) {
                Circle().fill(Color.white.opacity(0.42)).frame(width: 52).offset(y: -18)
                RoundedRectangle(cornerRadius: 14).fill(Color.indigo.opacity(0.38))
                    .frame(width: 40, height: 86).rotationEffect(.degrees(-22)).offset(y: 18)
                RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.4))
                    .frame(width: 40, height: 86).rotationEffect(.degrees(22)).offset(y: 20)
            }
            previewControl {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L("settings.glassIntensity.previewSearch"))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: 188, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border) }
        .accessibilityHidden(true)
    }

    private func previewControl(@ViewBuilder content: () -> some View) -> some View {
        content().frame(height: 34).foregroundStyle(StudioTheme.textPrimary)
            .background(AskGlassBackground(
                material: AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style),
                corner: 17,
                opaqueFill: AskTheme.glassFill,
                placement: .inWindow
            ))
    }
}
