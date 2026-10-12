import Foundation
import Testing
@testable import TypefluxUI

@Suite("TypefluxUI content state")
struct TypefluxUIControlStateTests {
    @Test func `only destructive buttons have a destructive role`() {
        for kind in TypefluxButtonKind.allCases {
            #expect((kind.role != nil) == (kind == .destructive))
        }
    }

    @Test func `slider normalizes invalid domains and steps without mutating state`() {
        for range in [0.0...1.0, -10.0...10.0] {
            let domain = TypefluxSliderDomain(range: range, step: 0.25)
            #expect(domain.range == range)
            #expect(domain.step == 0.25)
            #expect(domain.clamped(.nan) == range.lowerBound)
            #expect(domain.clamped(-.infinity) == range.lowerBound)
            #expect(domain.clamped(.infinity) == range.upperBound)
            #expect(domain.clamped(range.lowerBound) == range.lowerBound)
            #expect(domain.clamped(range.upperBound) == range.upperBound)
            #expect(domain.clamped(0.5) == 0.5)
        }
        for range in [1...1, -Double.infinity...1, 0...Double.infinity] {
            #expect(TypefluxSliderDomain(range: range, step: nil).range == 0...1)
        }
        for step in [0, -1, Double.nan, .infinity] {
            #expect(TypefluxSliderDomain(range: 0...1, step: step).step == nil)
        }
        #expect(TypefluxSliderDomain(range: 0...1, step: nil).step == nil)
    }

    @Test func `progress preserves indeterminate and clamps unsafe values`() {
        #expect(TypefluxProgressValue(value: nil, total: 100).value == nil)
        for total in [0, -1, Double.nan, .infinity, -.infinity] {
            let progress = TypefluxProgressValue(value: 0.5, total: total)
            #expect(progress.total == 1)
            #expect(progress.value == 0.5)
        }
        for value in [Double.nan, -Double.infinity, -1, 0] {
            #expect(TypefluxProgressValue(value: value, total: 100).value == 0)
        }
        for value in [100, 101, Double.infinity] {
            #expect(TypefluxProgressValue(value: value, total: 100).value == 100)
        }
        #expect(TypefluxProgressValue(value: 25, total: 100).value == 25)
    }

    @Test func `row actions are reachable by mouse selection keyboard and VoiceOver`() {
        for hovered in [false, true] {
            for selected in [false, true] {
                for focused in [false, true] {
                    for voiceOver in [false, true] {
                        let visible = TypefluxTableActionVisibility.isVisible(
                            hovered: hovered, selected: selected, focused: focused, voiceOver: voiceOver
                        )
                        #expect(visible == (hovered || selected || focused || voiceOver))
                    }
                }
            }
        }
    }

    @Test func `table hover survives adjacent cells reordered exits and recycled rows`() {
        let first = UUID()
        let second = UUID()
        var state = TypefluxTableHoverState()
        #expect(!state.isHovered(1))
        state.updateRow(cell: first, row: 1)
        #expect(!state.isHovered(1))
        state.update(cell: first, row: 1, hovering: true)
        state.update(cell: second, row: 1, hovering: true)
        #expect(state.isHovered(1))
        state.update(cell: first, row: 1, hovering: false)
        #expect(state.isHovered(1))
        state.updateRow(cell: second, row: 2)
        #expect(!state.isHovered(1))
        #expect(state.isHovered(2))
        state.update(cell: first, row: 1, hovering: false)
        #expect(state.isHovered(2))
        state.update(cell: second, row: 2, hovering: false)
        #expect(!state.isHovered(2))
    }
}
