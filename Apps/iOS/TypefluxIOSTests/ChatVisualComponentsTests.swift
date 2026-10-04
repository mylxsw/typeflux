import SwiftUI
import Testing
import TypefluxChat
@testable import TypefluxIOS
import UIKit

@MainActor
@Suite("Mac-aligned mobile visual components")
struct ChatVisualComponentsTests {
    @Test func `orb integrates eight seconds without jumping after background or clock skew`() {
        let clock = ChatOrbClock()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(clock.advance(to: start) == 0)
        for frame in 1 ... 60 {
            _ = clock.advance(to: start.addingTimeInterval(Double(frame) / 30))
        }
        #expect(abs(clock.phase - 0.25) < 0.000001)
        let beforeGap = clock.phase
        _ = clock.advance(to: start.addingTimeInterval(120))
        #expect(abs(clock.phase - beforeGap - 0.1 / 8) < 0.000001)
        let beforeSkew = clock.phase
        _ = clock.advance(to: start.addingTimeInterval(119))
        #expect(clock.phase == beforeSkew)
        for frame in 1 ... 300 {
            _ = clock.advance(to: start.addingTimeInterval(119 + Double(frame) / 30))
        }
        #expect(clock.phase >= 0 && clock.phase < 1)
    }

    @Test func `drop uses closed periodic 48 point outline within its frame`() {
        let bounds = CGRect(x: 10, y: 20, width: 88, height: 88)
        for phase in stride(from: 0.0, to: 1.0, by: 0.125) {
            var shape = ChatFluidDropShape(phase: phase)
            let points = shape.points(in: bounds)
            #expect(points.count == 48)
            #expect(points.allSatisfy { bounds.contains($0) })
            var closes = false
            shape.path(in: bounds).cgPath.applyWithBlock { element in
                if element.pointee.type == .closeSubpath {
                    closes = true
                }
            }
            #expect(closes)
            shape.animatableData = phase + 1
            #expect(shape.animatableData == phase + 1)
            let repeated = shape.points(in: bounds)
            #expect(zip(points, repeated).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.000001 })
        }
        let staticShape = ChatFluidDropShape(phase: ChatOrb.stillPhase)
        let radii = staticShape.points(in: bounds).map { hypot($0.x - bounds.midX, $0.y - bounds.midY) }
        #expect((radii.max() ?? 0) - (radii.min() ?? 0) > 2)
        #expect(ChatFluidDropShape(phase: 0).path(in: .zero).boundingRect == .zero)
    }

    @Test func `breathing and flowing gradient keep the Mac cycle and amplitude`() {
        #expect(ChatOrb.flowColors.count == 11)
        #expect(ChatOrb.breath(0) == 1)
        #expect(abs(ChatOrb.breath(0.25) - 1.035) < 0.000001)
        #expect(abs(ChatOrb.breath(1) - 1) < 0.000001)
        for step in 0 ... 32 {
            let phase = Double(step) / 32
            #expect(ChatOrb.breath(phase) >= 1 && ChatOrb.breath(phase) <= 1.0351)
            let flow = ChatOrb.flow(phase)
            let length = hypot(flow.end.x - flow.start.x, flow.end.y - flow.start.y)
            #expect(abs(length - 4.8) < 0.000001)
            let axisX = (flow.end.x - flow.start.x) / length
            let axisY = (flow.end.y - flow.start.y) / length
            let offset = (0.5 - flow.start.x) * axisX + (0.5 - flow.start.y) * axisY
            #expect(abs(offset - 2.4 * (0.5 + phase)) < 0.000001)
        }
    }

    @Test func `slider touch positions clamp and top level fills the whole track`() {
        for count in 2 ... 5 {
            let width: CGFloat = 248
            #expect(ChatEffortSlider.knobCenter(index: 0, count: count, width: width) == 13)
            let last = ChatEffortSlider.knobCenter(index: count - 1, count: count, width: width)
            #expect(last == 235)
            #expect(ChatEffortSlider.fillWidth(knobCenter: last, width: width) == width)
            #expect(ChatEffortSlider.index(at: -100, count: count, width: width) == 0)
            #expect(ChatEffortSlider.index(at: 1000, count: count, width: width) == count - 1)
            for stop in 0 ..< count {
                let center = ChatEffortSlider.knobCenter(index: stop, count: count, width: width)
                #expect(ChatEffortSlider.index(at: center, count: count, width: width) == stop)
            }
        }
        #expect(ChatEffortSlider.knobCenter(index: 0, count: 1, width: 100) == 50)
        #expect(ChatEffortSlider.knobCenter(index: 1, count: 3, width: 10) == 5)
        #expect(ChatEffortSlider.index(at: 50, count: 0, width: 100) == 0)
        #expect(ChatEffortSlider.index(at: 50, count: 1, width: 100) == 0)
    }

    @Test func `voiceOver first adjustment leaves Auto and later steps respect model limits`() {
        let levels: [ChatReasoningEffort] = [.low, .medium, .high]
        #expect(ChatEffortSlider.adjusted(.providerDefault, levels: levels, increase: true) == .medium)
        #expect(ChatEffortSlider.adjusted(.providerDefault, levels: levels, increase: false) == .medium)
        #expect(ChatEffortSlider.adjusted(.medium, levels: levels, increase: true) == .high)
        #expect(ChatEffortSlider.adjusted(.medium, levels: levels, increase: false) == .low)
        #expect(ChatEffortSlider.adjusted(.high, levels: levels, increase: true) == .high)
        #expect(ChatEffortSlider.adjusted(.low, levels: levels, increase: false) == .low)
        #expect(ChatEffortSlider.adjusted(.max, levels: levels, increase: false) == .medium)
        #expect(ChatEffortSlider.adjusted(.high, levels: [], increase: false) == .providerDefault)
        #expect(ChatEffortSlider.adjusted(.providerDefault, levels: [.high], increase: true) == .high)
    }

    @Test func `liquid particles are deterministic and stay in their unit interval`() {
        for index in 0 ..< ChatLiquidFill.particleCount {
            for salt in 1 ... 6 {
                let value = ChatLiquidFill.noise(index, Double(salt))
                #expect(value >= 0 && value < 1)
                #expect(value == ChatLiquidFill.noise(index, Double(salt)))
            }
        }
    }

    @Test func `model metadata hides invalid prices and preserves four decimal places`() {
        for value in ["invalid", "NaN", "inf", "0", "-1", "101", "1.12345", "1x", "1e2"] {
            #expect(ChatModelPickerDisplay
                .multiplier(ChatModel(id: "m", name: "M", pricing: ["multiplier": value])) == nil)
        }
        #expect(ChatModelPickerDisplay.multiplier(ChatModel(id: "m", name: "M")) == nil)
        for (raw, expected) in [("1", "1×"), ("2.5000", "2.5×"), ("0.0001", "0.0001×"), ("100", "100×")] {
            let model = ChatModel(id: "m", name: "M", pricing: ["multiplier": raw])
            #expect(ChatModelPickerDisplay.multiplier(model) == expected)
        }
        let model = ChatModel(id: "m", name: "M", contextWindowTokens: 205_000, maxOutputTokens: 16384)
        #expect(ChatModelPickerDisplay.capacity(model)?.contains("205K") == true)
        #expect(ChatModelPickerDisplay.capacity(ChatModel(id: "m", name: "M")) == nil)
        #expect(ChatModelPickerDisplay.capacity(ChatModel(
            id: "m",
            name: "M",
            contextWindowTokens: 0,
            maxOutputTokens: 2
        )) == nil)
        #expect(ChatModelPickerDisplay.count(2_000_000) == "2M")
        #expect(ChatModelPickerDisplay.count(200) == "200")
    }

    @Test func `effort labels and descriptions remain distinct`() {
        let all: [ChatReasoningEffort] = [.providerDefault, .low, .medium, .high, .xhigh, .max]
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(Set(all.map(\.caption)).count == all.count)
        #expect(all.allSatisfy { !$0.label.isEmpty && !$0.caption.isEmpty })
    }

    @Test func `theme resolves light and dark neutrals with a raised card hierarchy`() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = UIColor(ChatTheme.background).resolvedColor(with: traits)
            let card = UIColor(ChatTheme.card).resolvedColor(with: traits)
            var backgroundWhite: CGFloat = 0, cardWhite: CGFloat = 0
            background.getWhite(&backgroundWhite, alpha: nil)
            card.getWhite(&cardWhite, alpha: nil)
            #expect(cardWhite > backgroundWhite)
            #expect(style == .light ? backgroundWhite > 0.9 : backgroundWhite < 0.2)
        }
    }

    @Test func `every custom dynamic theme color resolves correctly off the main actor`() async {
        let colors = [
            ChatTheme.accent, ChatTheme.background, ChatTheme.card, ChatTheme.raised,
            ChatTheme.sidebar, ChatTheme.controlSurface, ChatTheme.popover, ChatTheme.accentText,
            ChatTheme.accentSoft, ChatTheme.purple, ChatTheme.border, ChatTheme.separator
        ].map { UIColor($0) }
        let expectedLight: [[CGFloat]] = [
            [0.18, 0.43, 0.94, 1], [0.985, 0.985, 0.985, 1], [1, 1, 1, 1],
            [0.965, 0.965, 0.965, 1], [0.940, 0.940, 0.940, 1], [0.925, 0.925, 0.925, 1],
            [1, 1, 1, 1], [0.106, 0.341, 0.839, 1], [0.906, 0.937, 1, 1],
            [0.49, 0.25, 0.94, 1], [0.886, 0.898, 0.918, 1], [0.910, 0.922, 0.937, 1]
        ]
        let expectedDark: [[CGFloat]] = [
            [0.09, 0.55, 1, 1], [0.122, 0.122, 0.122, 1], [0.180, 0.180, 0.180, 1],
            [0.150, 0.150, 0.150, 1], [0.075, 0.075, 0.075, 1], [0.180, 0.180, 0.180, 1],
            [0.196, 0.196, 0.196, 1], [0.557, 0.741, 1, 1], [0.082, 0.149, 0.243, 1],
            [0.71, 0.55, 1, 1], [1, 1, 1, 0.10], [1, 1, 1, 0.07]
        ]
        let resolved = await Task.detached { @Sendable in
            dispatchPrecondition(condition: .notOnQueue(.main))
            return [UIUserInterfaceStyle.light, .dark].map { style in
                let traits = UITraitCollection(userInterfaceStyle: style)
                return colors.map { color in
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    let success = color.resolvedColor(with: traits).getRed(
                        &red,
                        green: &green,
                        blue: &blue,
                        alpha: &alpha
                    )
                    return success ? [red, green, blue, alpha] : []
                }
            }
        }.value
        for (actual, expected) in zip(resolved.flatMap(\.self), expectedLight + expectedDark) {
            #expect(actual.count == expected.count)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 })
        }
    }

    @Test func `orb and slider preserve dimensions with reduced motion`() throws {
        let orb = ImageRenderer(content: ChatOrb(reduceMotionOverride: true))
        let image = try #require(orb.uiImage)
        #expect(image.size == CGSize(width: 88, height: 88))
        let first = ImageRenderer(content: ChatOrb().drop(phase: 0.15).frame(width: 88, height: 88))
        let second = ImageRenderer(content: ChatOrb().drop(phase: 0.4).frame(width: 88, height: 88))
        #expect(first.uiImage?.pngData() != second.uiImage?.pngData())
        for effort in [ChatReasoningEffort.providerDefault, .low, .high] {
            let slider = ImageRenderer(content: ChatEffortSlider(
                levels: [.low, .medium, .high],
                effort: .constant(effort),
                reduceMotionOverride: true
            )
            .frame(width: 248))
            let rendered = try #require(slider.uiImage)
            #expect(rendered.size == CGSize(width: 248, height: 44))
        }
        for reduced in [false, true] {
            let glass = ImageRenderer(content: Color.clear.frame(width: 100, height: 50)
                .chatGlass(reduceTransparency: reduced))
            #expect(try #require(glass.uiImage).size == CGSize(width: 100, height: 50))
        }
    }

    @Test func `popover uses natural short height and bounds long pages to keyboard space`() throws {
        for width: CGFloat in [272, 330] {
            let compact = ImageRenderer(content: ChatPopoverContent(maximumHeight: 420) {
                Color.blue.frame(height: 100)
            }.frame(width: width))
            #expect(try #require(compact.uiImage).size == CGSize(width: width, height: 100))

            for height: CGFloat in [120, 220, 420] {
                let overflowing = ImageRenderer(content: ChatPopoverContent(maximumHeight: height) {
                    VStack(spacing: 0) {
                        ForEach(0 ..< 12) { _ in
                            Text("A cloud model with a longer name")
                                .frame(height: 60)
                        }
                    }
                }.frame(width: width))
                #expect(try #require(overflowing.uiImage).size == CGSize(width: width, height: height))
            }
        }
    }
}
