import SwiftUI

struct LiquidGlassIntensitySetting: View {
    @Binding var value: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility

    var body: some View {
        LiquidGlassIntensityControl(value: $value, accessibilityOverride: reduceTransparency || contrast == .increased
            || accessibility.reduceTransparency || accessibility.increasedContrast)
    }
}

/// The environment adapter supplies the system accessibility policy to the control.
struct LiquidGlassIntensityControl: View {
    @Binding var value: Double
    let accessibilityOverride: Bool

    var body: some View {
        VStack(alignment: .leading) {
            TypefluxSettingsRow(L("settings.glassIntensity.title"),
                                description: L("settings.glassIntensity.subtitle")) {
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .accessibilityHidden(true)
            }
            TypefluxSlider(L("settings.glassIntensity.title"), value: $value)
                .labelsHidden()
                .accessibilityLabel(L("settings.glassIntensity.title"))
                .disabled(accessibilityOverride)
                .accessibilityHint(L("settings.glassIntensity.subtitle"))
                .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("settings.liquidGlassIntensity.slider")
            HStack {
                Text(L("settings.glassIntensity.clear"))
                Spacer()
                Text(L("settings.glassIntensity.tinted"))
            }.font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            if accessibilityOverride {
                Text(L("settings.glassIntensity.accessibility"))
                    .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
