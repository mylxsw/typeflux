import Foundation
import Testing
@testable import Typeflux

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceStateTests {
    @Test func wideSidebarChangesPersistAndRestoreThePreference() {
        let state = AskWorkspaceState()
        var collapsed = false
        var writes: [Bool] = []
        for expected in [true, false] {
            state.toggleSidebar(layout: AskWorkspaceLayout(size: .init(width: 1180, height: 760),
                sidebarCollapsed: collapsed, showsUsage: false), collapsed: collapsed, reduceMotion: true) {
                collapsed = $0
                writes.append($0)
            }
            #expect(state.sidebarChoice == expected)
            #expect(collapsed == expected)
            #expect(!state.showsSidebarDrawer)
        }
        #expect(writes == [true, false])
    }

    @Test func narrowDrawerClosesOverlayUsageWithoutChangingThePreference() {
        let state = AskWorkspaceState(showsUsage: true)
        var writes = 0
        for expected in [true, false] {
            state.toggleSidebar(layout: AskWorkspaceLayout(size: .init(width: 440, height: 320),
                sidebarCollapsed: true, showsUsage: state.showsUsage), collapsed: true, reduceMotion: true) { _ in
                writes += 1
            }
            #expect(state.showsSidebarDrawer == expected)
            #expect(!state.showsUsage)
            #expect(state.sidebarChoice == nil)
        }
        #expect(writes == 0)
    }

    @Test func usageAndSearchKeepOnlyOneModalAndPreserveTheSelectedRun() {
        let state = AskWorkspaceState()
        state.showsSidebarDrawer = true
        state.isSearching = true
        state.toggleUsage(runId: "run", reduceMotion: true)
        #expect(state.showsUsage)
        #expect(state.usageRunId == "run")
        state.setUsage(true, reduceMotion: true)
        #expect(state.usageRunId == "run")
        #expect(!state.showsSidebarDrawer && !state.isSearching)
        var closedWorkflow = false
        state.openSearch(reduceMotion: true) { closedWorkflow = true }
        #expect(!state.showsUsage && state.isSearching)
        #expect(closedWorkflow)
        state.toggleUsage(runId: "next", reduceMotion: true)
        #expect(state.showsUsage && !state.isSearching)
        #expect(state.usageRunId == "next")
        state.toggleUsage(runId: "ignored", reduceMotion: true)
        #expect(!state.showsUsage)
        #expect(state.usageRunId == "next")
    }

    @Test func closingHistoryPreservesTheUnderlyingWorkflow() {
        let state = AskWorkspaceState()
        state.showsSidebarDrawer = true
        var closedWorkflow = false
        state.closeDrawer(reduceMotion: true) { closedWorkflow = true }
        #expect(!state.showsSidebarDrawer)
        #expect(!closedWorkflow)
    }
}
