import SwiftUI

/// Provider assets are decoded once, never during scrolling.
@MainActor
struct ModelProviderIcon: View {
    let provider: StudioModelProviderID
    var size: CGFloat = 28

    private static let images: [StudioModelProviderID: NSImage] = Dictionary(
        uniqueKeysWithValues: StudioModelProviderID.allCases.compactMap { provider in
            loadImage(for: provider).map { (provider, $0) }
        }
    )

    static func image(for provider: StudioModelProviderID) -> NSImage? {
        images[provider]
    }

    var body: some View {
        Group {
            if provider.usesTypefluxBranding {
                TypefluxLogoBadge(size: size, symbolSize: size / 2,
                                  backgroundShape: .circle, showsBorder: true)
            } else if let image = Self.images[provider] {
                Image(nsImage: image)
                    .renderingMode(Self.isMonochrome(provider) ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit().padding(3)
                    .foregroundStyle(StudioTheme.textPrimary)
            } else {
                Image(systemName: Self.symbol(for: provider))
                    .font(.system(size: size * 0.55, weight: .medium))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    static func isMonochrome(_ provider: StudioModelProviderID) -> Bool {
        guard let resource = resourceName(for: provider) else { return false }
        return ["openai", "ollama", "moonshot", "xai", "openrouter", "opencode"].contains(resource)
    }

    private static func loadImage(for provider: StudioModelProviderID) -> NSImage? {
        guard let resourceName = resourceName(for: provider) else { return nil }

        let url =
            Bundle.appResources.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Resources/Providers"
            )
            ?? Bundle.appResources.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Providers"
            )
            ?? Bundle.appResources.url(forResource: resourceName, withExtension: "png")
            ?? Bundle.appResources.url(forResource: resourceName, withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.appResources.url(forResource: resourceName, withExtension: "svg")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    static func resourceName(for provider: StudioModelProviderID) -> String? {
        switch provider {
        case .freeSTT:
            nil
        case .whisperAPI, .multimodalLLM:
            "openai"
        case .ollama:
            "ollama"
        case .freeModel:
            nil
        case .openRouter:
            "openrouter"
        case .openAI:
            "openai"
        case .anthropic:
            "claude-color"
        case .gemini:
            "gemini-color"
        case .deepSeek:
            "deepseek-color"
        case .kimi:
            "moonshot"
        case .qwen:
            "qwen-color"
        case .zhipu:
            "zhipu-color"
        case .minimax:
            "minimax-color"
        case .grok:
            "xai"
        case .groq:
            "groq"
        case .groqSTT:
            "groq"
        case .googleCloud:
            "google"
        case .xiaomi:
            "xiaomimimo"
        case .openCodeZen, .openCodeGo:
            "opencode"
        case .aliCloud:
            "bailian-color"
        case .doubaoRealtime:
            "doubao-color"
        default:
            nil
        }
    }

    static func symbol(for provider: StudioModelProviderID) -> String {
        switch provider {
        case .appleSpeech:
            "waveform"
        case .localSTT:
            "laptopcomputer.and.arrow.down"
        case .freeSTT:
            "giftcard"
        case .whisperAPI:
            "dot.radiowaves.left.and.right"
        case .ollama:
            "cpu"
        case .freeModel:
            "giftcard"
        case .customLLM:
            "xmark.triangle.circle.square.fill"
        case .openRouter:
            "arrow.triangle.branch"
        case .openAI:
            "circle.hexagongrid"
        case .anthropic:
            "sun.max"
        case .gemini:
            "diamond"
        case .deepSeek:
            "bird"
        case .kimi:
            "moon.stars"
        case .qwen:
            "cloud"
        case .zhipu:
            "dot.scope"
        case .minimax:
            "sparkles"
        case .grok:
            "x.circle"
        case .groq:
            "bolt.fill"
        case .groqSTT:
            "bolt.fill"
        case .xiaomi:
            "circle.grid.cross"
        case .openCodeZen:
            "sparkle.magnifyingglass"
        case .openCodeGo:
            "hare"
        case .multimodalLLM:
            "brain.filled.head.profile"
        case .aliCloud:
            "antenna.radiowaves.left.and.right"
        case .doubaoRealtime:
            "bolt.horizontal.circle"
        case .googleCloud:
            "cloud"
        case .soniox:
            "waveform.and.mic"
        case .typefluxOfficial:
            "infinity"
        case .typefluxCloud:
            "infinity"
        }
    }
}

extension RegisteredProvider {
    var studioProviderID: StudioModelProviderID {
        isOllama ? .ollama : remote?.studioProviderID ?? .customLLM
    }
}
