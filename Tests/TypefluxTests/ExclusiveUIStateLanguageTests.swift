import Foundation
import Testing
@testable import Typeflux

/// `L()` reads the process-wide `AppLocalization.shared.language`, and tests that switch it hold
/// `.exclusiveUIState`. A test that reads localized text without the trait can run while a writer
/// holds the lock and see the other language, whatever `interface:` value it passes elsewhere.
@Suite("Global language isolation", .serialized, .exclusiveUIState)
struct ExclusiveUIStateLanguageTests {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor Reads {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    @Test func aLockedReaderWaitsForTheLanguageWriterWhileAnUnlockedReaderSeesTheSwitch() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let key = "ask.voice.input"
        let originalText = L(key)
        AppLocalization.shared.setLanguage(switched)
        let switchedText = L(key)
        AppLocalization.shared.setLanguage(original)
        #expect(switchedText != originalText)

        // A private lock stands in for the shared one, which this suite already holds.
        let lock = ExclusiveUIStateLock()
        let trait = ExclusiveUIStateTrait(lock: lock)
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let writerSwitched = Gate(), writerMayRestore = Gate()
        let reads = Reads()

        let writer = Task {
            try await trait.provideScope(for: test, testCase: testCase) {
                AppLocalization.shared.setLanguage(switched)
                await writerSwitched.signal()
                await writerMayRestore.wait()
                AppLocalization.shared.setLanguage(original)
            }
        }
        await writerSwitched.wait()
        await reads.append("unlocked: " + L(key))
        let reader = Task {
            try await trait.provideScope(for: test, testCase: testCase) {
                await reads.append("locked: " + L(key))
            }
        }
        var polls = 0
        while await lock.waiterCount == 0, polls < 1000 {
            polls += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await lock.waiterCount == 1)
        #expect(await reads.values == ["unlocked: " + switchedText])
        await writerMayRestore.signal()
        try await writer.value
        try await reader.value

        #expect(await reads.values == ["unlocked: " + switchedText, "locked: " + originalText])
        #expect(await !lock.isLocked)
    }

    /// Every Swift Testing suite that reads localized text or switches the language must share the
    /// lock. Extensions in other files count toward the suite they extend.
    @Test func everySuiteThatReadsTheGlobalLanguageIsExclusive() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var sources: [String: [String]] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            if lines.contains("import Testing") { sources[file.lastPathComponent] = lines }
        }
        #expect(sources.count > 100, "The audit must see the Swift Testing sources")

        let readsLanguage = try NSRegularExpression(pattern: #"\bL\(|AppLocalization|\binterface:\s*\."#)
        let testAttribute = try NSRegularExpression(pattern: #"(?m)^\s+@Test\b"#)
        let modifiers = #"(?:(?:private|fileprivate|internal|public|final)\s+)*"#
        let declaration = try NSRegularExpression(
            pattern: #"^(?:@MainActor\s+)?"# + modifiers + #"(?:struct|class|enum|actor)\s+(\w+)"#)
        let extensionHeader = try NSRegularExpression(pattern: #"^(?:private\s+)?extension\s+(\w+)"#)
        func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        func name(_ expression: NSRegularExpression, _ line: String) -> String? {
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
        func body(_ lines: [String], after index: Int) -> String {
            lines[(index + 1)...].prefix { !$0.hasPrefix("}") }.joined(separator: "\n")
        }

        var extensionBodies: [String: [String]] = [:]
        for lines in sources.values {
            for (index, line) in lines.enumerated() {
                if let extended = name(extensionHeader, line) {
                    extensionBodies[extended, default: []].append(body(lines, after: index))
                }
            }
        }
        var missing: [String] = []
        for (file, lines) in sources {
            for (index, line) in lines.enumerated() {
                guard let type = name(declaration, line) else { continue }
                let suiteLines = lines[..<index].reversed()
                    .prefix { $0.hasPrefix("@") || $0.hasPrefix("//") }
                    .filter { $0.hasPrefix("@Suite") }
                let bodies = [body(lines, after: index)] + extensionBodies[type, default: []]
                let isSuite = !suiteLines.isEmpty || bodies.contains { matches(testAttribute, $0) }
                guard isSuite, bodies.contains(where: { matches(readsLanguage, $0) }) else { continue }
                if !suiteLines.contains(where: { $0.contains(".exclusiveUIState") }) {
                    missing.append("\(file): \(type)")
                }
            }
        }
        #expect(missing.sorted() == [], "Add .exclusiveUIState to these suites")
    }
}
