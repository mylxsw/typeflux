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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("settings.glassIntensity.title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(StudioTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            LiquidGlassIntensityPreview()
                .environment(\.liquidGlassIntensity, LiquidGlassIntensity(value))
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
            if accessibilityOverride {
                Text(L("settings.glassIntensity.accessibility"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Real shared glass over an intentionally varied scene, so the preview changes
/// with the same material policy as the app's controls rather than a mock image.
struct LiquidGlassIntensityPreview: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.61, blue: 0.91),
                                    Color(red: 0.50, green: 0.82, blue: 0.75),
                                    Color(red: 0.91, green: 0.61, blue: 0.46)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 28).fill(Color.indigo.opacity(0.65))
                    .frame(width: 70, height: 130).rotationEffect(.degrees(-20)).offset(y: 25)
                Circle().fill(Color.white.opacity(0.55)).frame(width: 80).offset(y: -25)
                RoundedRectangle(cornerRadius: 24).fill(Color.orange.opacity(0.65))
                    .frame(width: 70, height: 140).rotationEffect(.degrees(20)).offset(y: 35)
            }
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 10) {
                    previewControl { Image(systemName: "square.and.arrow.up").frame(width: 44) }
                    previewControl { Image(systemName: "square.on.square").frame(width: 44) }
                    previewControl {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                            Text(L("settings.glassIntensity.previewSearch")).font(.system(size: 14))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 14)
                    }
                }.font(.system(size: 18))
                Text("Typeflux").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
            }.padding(16)
        }
        .frame(height: 156)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private func previewControl(@ViewBuilder content: () -> some View) -> some View {
        content().frame(height: 44).foregroundStyle(StudioTheme.textPrimary)
            .background(AskGlassBackground(
                material: AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style),
                corner: 22,
                opaqueFill: AskTheme.glassFill,
                placement: .inWindow
            ))
    }
}
