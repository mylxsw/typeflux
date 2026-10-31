import SwiftUI

struct OnboardingRoutePage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingRouteModel
    @Environment(\.colorScheme) private var colorScheme
    private func text(_ key: String) -> String {
        OnboardingStrings.text(key, table: "OnboardingRoute")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            OnboardingEditorialHeader(eyebrow: text("eyebrow"), title: text("title"),
                                      subtitle: text("subtitle"), pill: OnboardingStep.route.pill, centered: true)
                .padding(.bottom, 24)
            HStack(spacing: 20) {
                card(.cloud, title: "Typeflux Cloud", detail: text("cloudDetail")) { cloudArt }
                card(.custom, title: text("customTitle"), detail: text("customDetail")) { ownArt }
            }.frame(maxWidth: 780)
            Button(OnboardingStrings.text("skipAll")) { viewModel.requestSetupSkip() }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.top, 20)
            Spacer(minLength: 0)
        }.padding(.horizontal, 34)
    }

    private func card(_ route: OnboardingViewModel.ServiceRoute, title: String, detail: String,
                      @ViewBuilder art: () -> some View) -> some View {
        let selected = viewModel.serviceRoute == route
        return Button { select(route) } label: {
            VStack(spacing: 0) {
                art().frame(height: 156).clipShape(RoundedRectangle(cornerRadius: 13))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 16, weight: .bold))
                            if route == .cloud {
                                Text(text("recommended").uppercased()).font(.system(size: 9, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.accentColor).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                        }
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    radio(selected: selected).padding(.top, 2)
                }.padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 8)
            }
            .padding(10)
            .background(cardFill(selected: selected))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(
                selected ? (colorScheme == .dark ? Color.white : .accentColor).opacity(0.28) : .primary.opacity(0.08)
            ))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 21).stroke(Color.accentColor.opacity(0.85), lineWidth: 1.2)
                        .padding(-3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { select(route, continueImmediately: true) })
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(route) }
    }

    private func select(_ route: OnboardingViewModel.ServiceRoute, continueImmediately: Bool = false) {
        guard viewModel.currentStep == .route else { return }
        viewModel.chooseRoute(route)
        if continueImmediately {
            viewModel.advance()
        }
    }

    private func cardFill(selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark ? color(0x3A3A40).opacity(0.96) : .accentColor.opacity(0.07)
        }
        return colorScheme == .dark ? .white.opacity(0.045) : .white
    }

    private func radio(selected: Bool) -> some View {
        ZStack {
            if selected {
                Circle().fill(Color.accentColor)
                Circle().fill(.white).frame(width: 7, height: 7)
            } else {
                Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
            }
        }.frame(width: 18, height: 18)
    }

    private var cloudArt: some View {
        ZStack {
            artBackground(cloud: true)
            ForEach([118.0, 186.0], id: \.self) { size in
                Circle().stroke(colorScheme == .dark ? .white.opacity(0.12) : color(0x503CA0).opacity(0.14))
                    .frame(width: size, height: size)
            }
            Image(nsImage: HelpAppIcon.image).resizable().frame(width: 58, height: 58)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 15, y: 10)
        }
        .frame(height: 156)
        .overlay(alignment: .topLeading) {
            chip(text("speech"), symbol: "waveform").padding(.leading, 30).padding(.top, 30)
        }
        .overlay(alignment: .topTrailing) {
            chip(text("rewrite"), symbol: "sparkles").padding(.trailing, 26).padding(.top, 48)
        }
        .overlay(alignment: .bottomLeading) {
            chip("Agent", symbol: "bubble.left").padding(.leading, 58).padding(.bottom, 24)
        }
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }

    private var ownArt: some View {
        let providers: [StudioModelProviderID] = [.openAI, .anthropic, .deepSeek, .gemini, .ollama, .qwen,
                                                  .openRouter, .doubaoRealtime]
        return ZStack {
            artBackground(cloud: false)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 12), count: 4), spacing: 12) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                    if let image = ModelProviderIcon.image(for: provider) {
                        Image(nsImage: image).resizable().scaledToFit().padding(6)
                            .frame(width: 38, height: 38).background(.white, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.black.opacity(0.08)))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
                            .offset(y: index.isMultiple(of: 2) ? -6 : 0)
                    }
                }
            }
        }
    }

    private func artBackground(cloud: Bool) -> some View {
        let palette: [UInt32] = if cloud {
            colorScheme == .dark ? [0x4B3A8C, 0x2A2350, 0x16151D] : [0xDCD2FF, 0xECE7FB, 0xF7F6FB]
        } else {
            colorScheme == .dark ? [0x203A4D, 0x1B2330, 0x141519] : [0xD6E8F5, 0xEAF1F7, 0xF6F7F9]
        }
        let midpoint: CGFloat = cloud && colorScheme == .dark ? 0.45 : 0.5
        let stops = zip(palette, [0, midpoint, 1]).map { Gradient.Stop(color: color($0.0), location: $0.1) }
        return EllipticalGradient(gradient: Gradient(stops: stops), center: UnitPoint(x: cloud ? 0.3 : 0.7, y: 0),
                                  endRadiusFraction: 1.2)
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}
