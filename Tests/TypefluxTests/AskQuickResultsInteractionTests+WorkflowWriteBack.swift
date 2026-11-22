import AppKit
import Foundation
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func typedJSONStaysVisibleUntilTheUserRequestsWriteBack() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            _ = try workflows.store.add(try #require(AskWorkflowGallery.bundled.item("json")), builtIn: [])
            var delivered: [String] = []
            let launcher = try await Launcher(text: "") { model in
                model.workflows = workflows.store
                model.deliverText = { delivered.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            await model.refreshLauncherWorkflows()
            for character in #"json {"a":1}"# {
                launcher.editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            try await launcher.fixture.wait { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await launcher.fixture.wait { model.plugins.output != nil }
            let output = try #require(model.plugins.output)
            try await Task.sleep(for: .milliseconds(200))
            #expect(model.plugins.output?.body == "{\n  \"a\": 1\n}")
            #expect(launcher.dismissed == 0 && delivered.isEmpty)
            #expect(pasteboard.string(forType: .string) == nil)

            try await launcher.press(Self.returnKey, .option)
            try await launcher.fixture.wait { !delivered.isEmpty }
            #expect(delivered == [output.body])
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func selectionOnlyJSONStillWritesBackAutomatically() async throws {
        try await withPasteboard { _ in
            let workflows = try AskWorkflowFixture()
            _ = try workflows.store.add(try #require(AskWorkflowGallery.bundled.item("json")), builtIn: [])
            var delivered: [String] = []
            let launcher = try await Launcher(text: "", selection: #"{"a":1}"#) { model in
                model.workflows = workflows.store
                model.deliverText = { delivered.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            await model.refreshLauncherWorkflows()
            for character in "json " {
                launcher.editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            try await launcher.fixture.wait { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await launcher.fixture.wait { !delivered.isEmpty }
            #expect(delivered == ["{\n  \"a\": 1\n}"])
            #expect(launcher.dismissed == 1)
        }
    }
}
