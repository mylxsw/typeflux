import SwiftUI

/// Developer readouts for the shared system. Later components can add sections here.
public struct TypefluxGalleryView: View {
    @Binding private var style: InterfaceStyle
    @Binding private var appearance: ColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.glassMaterialOverride) private var materialOverride
    private let labels: TypefluxGalleryLabels
    private var components = AnyView(EmptyView())

    public init(style: Binding<InterfaceStyle>, appearance: Binding<ColorScheme>, labels: TypefluxGalleryLabels) {
        _style = style
        _appearance = appearance
        self.labels = labels
    }

    public init<Content: View>(
        style: Binding<InterfaceStyle>, appearance: Binding<ColorScheme>,
        labels: TypefluxGalleryLabels, @ViewBuilder components: () -> Content
    ) {
        self.init(style: style, appearance: appearance, labels: labels)
        self.components = AnyView(components())
    }

    private var tokens: TypefluxTokens {
        TypefluxTokens(style: style, colorScheme: appearance, reduceTransparency: reduceTransparency,
                       increasedContrast: contrast == .increased)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(labels.style, selection: $style) {
                    Text(labels.classic).tag(InterfaceStyle.classic)
                    Text(labels.liquidGlass).tag(InterfaceStyle.liquidGlass)
                }.pickerStyle(.segmented).accessibilityIdentifier("typeflux.gallery.style")
                Picker(labels.appearance, selection: $appearance) {
                    Text(labels.light).tag(ColorScheme.light)
                    Text(labels.dark).tag(ColorScheme.dark)
                }.pickerStyle(.segmented).accessibilityIdentifier("typeflux.gallery.appearance")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(GlassBackground(material: materialOverride ?? tokens.material, corner: 0,
                                        opaqueFill: TypefluxColor.windowBackground.color, placement: .inWindow))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(labels.colors).font(.headline)
                            ForEach(TypefluxColor.allCases, id: \.self) { token in
                                HStack {
                                    RoundedRectangle(cornerRadius: tokens.radius(.button))
                                        .fill(Color(nsColor: tokens.color(token)))
                                        .frame(width: 32, height: 24)
                                        .overlay(RoundedRectangle(cornerRadius: tokens.radius(.button))
                                            .stroke(TypefluxColor.separator.color))
                                    Text(token.rawValue).font(.body)
                                }.accessibilityElement(children: .combine)
                            }
                            Text(labels.typography).font(.headline).padding(.top)
                            ForEach(TypefluxTextStyle.allCases, id: \.self) { token in
                                Text(token.rawValue + " · " + labels.sampleText).font(token.font)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(labels.metrics).font(.headline)
                            ForEach(TypefluxRadius.allCases, id: \.self) { token in
                                readout("radius." + token.rawValue, value: tokens.radius(token))
                            }
                            Divider()
                            ForEach(TypefluxControlHeight.allCases, id: \.self) { token in
                                readout("height." + token.rawValue, value: tokens.height(token))
                            }
                            Divider()
                            ForEach(TypefluxControlWidth.allCases, id: \.self) { token in
                                readout("width." + token.rawValue, value: tokens.width(token))
                            }
                            ForEach(TypefluxSpacing.allCases, id: \.self) { token in
                                readout("spacing." + token.rawValue, value: tokens.spacing(token))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(24)
                    components.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }.background(TypefluxColor.contentBackground.color)
        }
        .foregroundStyle(TypefluxColor.label.color)
        .environment(\.interfaceStyle, style)
        .environment(\.colorScheme, appearance)
    }

    private func readout(_ name: String, value: CGFloat) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value, format: .number).monospacedDigit()
        }.font(.callout).accessibilityElement(children: .combine)
    }
}
