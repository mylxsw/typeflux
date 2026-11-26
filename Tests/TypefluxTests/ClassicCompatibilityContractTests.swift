import Foundation
import SQLite3
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct ClassicCompatibilityContractTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ClassicContract", isDirectory: true)

    private static let sampleID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private static let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func settingsMigrationsPreserveClassicPreferences() throws {
        let fixture = try Self.readPlist(Self.fixtures.appendingPathComponent("v0.4.0-defaults.plist"))
        #expect(fixture.count == 73)
        try withDefaults(seed: fixture) { defaults, suite in
            let settings = SettingsStore(defaults: defaults)
            _ = settings.personasJSON
            #expect(settings.voiceProcessingTimeout == .fortySeconds)
            let migratedHotkey = try #require(settings.activationHotkey)
            let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
            library.adoptLegacySelectionIfNeeded()
            #expect(!library.rewriteReference.isEmpty)

            let persisted = try #require(defaults.persistentDomain(forName: suite))
            for (key, original) in fixture {
                guard let stored = persisted[key] else {
                    Issue.record("Classic preference disappeared: \(key)")
                    continue
                }
                // Compare plist encodings to distinguish booleans, integers and reals.
                let before = try Self.plist(["value": original])
                let after = try Self.plist(["value": stored])
                switch key {
                case "hotkey.activation.json":
                    let json = try #require(stored as? String)
                    let hotkey = try JSONDecoder().decode(ClassicHotkey.self, from: Data(json.utf8))
                    #expect(hotkey.keyCode == 63)
                    #expect(hotkey.modifierFlags == 8_388_608)
                    #expect(hotkey.id == migratedHotkey.id)
                case "voice.processing.timeoutSeconds":
                    // Both releases migrate the old 60-second value to the integer preset 30.
                    #expect(after == (try Self.plist(["value": 30])))
                default:
                    #expect(before == after, "Classic preference changed: \(key)")
                }
            }

            settings.activationHotkey = nil
            #expect(defaults.object(forKey: "hotkey.custom.json") == nil)
            #expect(settings.activationHotkey == nil)
        }
    }

    @Test func historySchemaAndEnumsMatchClassic() throws {
        try withTemporaryDirectory { directory in
            let database = try writeHistory(in: directory)
            try checkClassicHistorySchema(database)
        }

        #expect(Set(HistoryRecord.Mode.allCases.map(\.rawValue)) == [
            "dictation", "personaRewrite", "editSelection", "askAnswer"
        ])
        #expect(Set(HistoryRecord.StepStatus.allCases.map(\.rawValue)) == [
            "pending", "running", "succeeded", "failed", "skipped"
        ])
    }

    @Test func legacyApplicationSupportPathRemainsUsableAfterMigration() throws {
        try withTemporaryDirectory { home in
            let legacy = home.appendingPathComponent("Library/Application Support/Typeflux", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let database = try writeHistory(in: legacy)
            let layout = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
            #expect(layout.migrationErrors.isEmpty)
            #expect(layout.data != legacy)
            #expect(database.resolvingSymlinksInPath() ==
                layout.data.appendingPathComponent("history.sqlite").resolvingSymlinksInPath())
            try checkClassicHistorySchema(database)
            try checkSampleHistoryRow(database)
        }
    }

    @Test func freshDataDirectoryIsAlsoAccessibleToClassic() throws {
        try withTemporaryDirectory { home in
            let layout = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
            #expect(layout.migrationErrors.isEmpty)
            _ = try writeHistory(in: layout.data)
            let legacy = home.appendingPathComponent("Library/Application Support/Typeflux/history.sqlite")
            try checkSampleHistoryRow(legacy)

            let repeated = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
            #expect(repeated.migrationErrors.isEmpty)
            #expect(repeated.data == layout.data)
        }
    }

    @Test func exportedFixturesMatchProductionWriters() throws {
        let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLASSIC_FIXTURE_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        try withTemporaryDirectory { directory in
            let database = try writeHistory(in: directory)
            if let output {
                try FileManager.default.copyItem(at: database, to: output.appendingPathComponent("history.sqlite"))
            }
            // A read-only SQLite connection can still create WAL sidecars next to the database.
            let copy = directory.appendingPathComponent("exported.sqlite")
            let exported = (output ?? Self.fixtures).appendingPathComponent("history.sqlite")
            try FileManager.default.copyItem(at: exported, to: copy)
            try checkClassicHistorySchema(copy)
            try checkSampleHistoryRow(copy)
        }

        try withDefaults(seed: ["ring.hotkeySeeded": true]) { defaults, suite in
            let settings = SettingsStore(defaults: defaults)
            let persona = PersonaProfile(id: Self.sampleID, name: "Classic", prompt: "Polish dictated text.")
            settings.personas = [persona]
            let personaJSON = Data(settings.personasJSON.utf8)
            let classicPersonas = try JSONDecoder().decode([ClassicPersona].self, from: personaJSON)
            let classicPersona = try #require(classicPersonas.first)
            #expect(classicPersonas.count == 1)
            #expect(classicPersona.id == persona.id)
            #expect(classicPersona.name == persona.name)
            #expect(classicPersona.prompt == persona.prompt)
            #expect(classicPersona.kind == .custom)
            try checkFixture("personas.json", data: Self.sortedJSON(personaJSON), output: output)

            let binding = HotkeyBinding(
                id: Self.sampleID, keyCode: 56, modifierFlags: 8_519_680, pressCount: 2, modifierKeyCodes: [56, 63]
            )
            settings.activationHotkey = binding
            let hotkeyJSON = Data(settings.activationHotkeyJSON.utf8)
            let classicHotkey = try JSONDecoder().decode(ClassicHotkey.self, from: hotkeyJSON)
            #expect(classicHotkey.id == binding.id)
            #expect(classicHotkey.keyCode == binding.keyCode)
            #expect(classicHotkey.modifierFlags == binding.modifierFlags)
            #expect(classicHotkey.pressCount == binding.pressCount)
            #expect(classicHotkey.modifierKeyCodes == binding.modifierKeyCodes)
            try checkFixture("hotkey.json", data: Self.sortedJSON(hotkeyJSON), output: output)

            let entries = [
                VocabularyEntry(id: Self.sampleID, term: "Typeflux", source: .manual, createdAt: Self.sampleDate,
                                occurrenceCount: 3)
            ]
            let vocabulary = try JSONEncoder().encode(entries)
            let classicEntries = try JSONDecoder().decode([ClassicVocabularyEntry].self, from: vocabulary)
            let classicEntry = try #require(classicEntries.first)
            #expect(classicEntries.count == 1)
            #expect(classicEntry.id == Self.sampleID)
            #expect(classicEntry.term == "Typeflux")
            #expect(classicEntry.source == .manual)
            #expect(classicEntry.createdAt == Self.sampleDate)
            #expect(classicEntry.occurrenceCount == 3)
            try checkFixture("vocabulary.json", data: Self.sortedJSON(vocabulary), output: output)

            try checkModelPreferences(defaults, suite: suite, output: output)
        }
    }

    private func checkModelPreferences(_ defaults: UserDefaults, suite: String, output: URL?) throws {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let providers: [RegisteredProvider] = [
            .init(id: "openAI", name: "OpenAI", remote: .openAI, models: [
                .init(id: "gpt-4o-mini", name: "GPT-4o mini", reference: "custom:fixture-openai")
            ]),
            .init(id: "typefluxCloud", name: "Typeflux Cloud", remote: .typefluxCloud, models: [
                .init(id: "default", name: "Typeflux Cloud", reference: "cloud:default")
            ]),
            .init(id: "ollama", name: "Ollama", baseURL: "http://127.0.0.1:11434", models: [
                .init(id: "qwen3:8b", name: "Qwen3", reference: "custom:fixture-ollama")
            ]),
            .init(id: "endpoint:fixture", name: "Fixture Endpoint", baseURL: "https://example.invalid/v1", models: [
                .init(id: "fixture-model", name: "Fixture Model", reference: "custom:fixture-endpoint")
            ], apiStyle: .openAICompatible)
        ]
        let registry = ModelRegistry(providers: providers)
        try library.commit(registry)
        try library.replaceRewriteModels([.init(id: "default", name: "Typeflux Cloud", scenarios: ["rewrite"])])

        for (file, provider) in zip(["defaults.plist", "defaults-cloud.plist", "defaults-ollama.plist",
                                     "defaults-endpoint.plist"], providers) {
            let model = try #require(provider.models.first)
            library.rewriteReference = model.reference
            let domain = try #require(defaults.persistentDomain(forName: suite))
            var snapshot: [String: Any] = [:]
            for key in [ModelRegistry.storageKey, AskModelLibrary.rewriteCatalogKey] {
                snapshot[key] = try Self.sortedJSON(try #require(domain[key] as? Data), prettyPrinted: false)
            }
            snapshot["llm.profile.reference"] = try #require(domain["llm.profile.reference"] as? String)
            try checkFixture(file, data: Self.plist(snapshot), output: output)
            let persisted = try Self.readPlist((output ?? Self.fixtures).appendingPathComponent(file))
            let data = try #require(persisted[ModelRegistry.storageKey] as? Data)
            let reference = try #require(persisted["llm.profile.reference"] as? String)
            let decoded = try JSONDecoder().decode(ModelRegistry.self, from: data)
            #expect(decoded == registry)
            #expect(decoded.resolve(reference)?.0 == provider)
            #expect(decoded.resolve(reference)?.1 == model)
        }
    }

    private func writeHistory(in directory: URL) throws -> URL {
        let store = SQLiteHistoryStore(baseDir: directory)
        store.save(record: HistoryRecord(
            id: Self.sampleID, date: Self.sampleDate, transcriptText: "Classic history fixture",
            recordingStatus: .succeeded, transcriptionStatus: .succeeded,
            processingStatus: .skipped, applyStatus: .succeeded
        ))
        // The synchronous read drains the write queue before the store closes and checkpoints WAL.
        let saved = try #require(store.record(id: Self.sampleID))
        #expect(saved.transcriptText == "Classic history fixture")
        return directory.appendingPathComponent("history.sqlite")
    }

    private func checkClassicHistorySchema(_ database: URL) throws {
        // v0.4.0 Sources/Typeflux/History/SQLiteHistoryStore.swift.
        let required = ["id": "TEXT", "date": "REAL", "mode": "TEXT", "recording_status": "TEXT",
                        "transcription_status": "TEXT", "processing_status": "TEXT", "apply_status": "TEXT"]
        let optionalText = ["audio_file_path", "transcript_text", "persona_prompt", "persona_result_text",
                            "open_cc_result_text", "open_cc_config", "post_processed_text", "selection_original_text",
                            "selection_edited_text", "pipeline_timing_json", "pipeline_stats_json", "error_message",
                            "apply_message"]
        var expected = required.mapValues { Column(type: $0, notNull: true) }
        for name in optionalText { expected[name] = Column(type: "TEXT", notNull: false) }
        expected["recording_duration_seconds"] = Column(type: "REAL", notNull: false)

        var actual: [String: Column] = [:]
        try readRows(database, sql: "PRAGMA table_info(history_records)") { row in
            actual[Self.text(row, 1)] = Column(type: Self.text(row, 2), notNull: sqlite3_column_int(row, 3) == 1)
            #expect(sqlite3_column_int(row, 5) == (Self.text(row, 1) == "id" ? 1 : 0))
        }
        for (name, column) in expected {
            #expect(actual[name] == column, "Classic column changed: \(name)")
        }
        for (name, column) in actual where expected[name] == nil {
            #expect(!column.notNull, "New history column must be nullable: \(name)")
        }
    }

    private func checkSampleHistoryRow(_ database: URL) throws {
        var ids: [String] = []
        let sql = """
            SELECT id, date, mode, transcript_text, recording_status, transcription_status,
                   processing_status, apply_status
            FROM history_records
            """
        try readRows(database, sql: sql) { row in
            ids.append(Self.text(row, 0))
            #expect(sqlite3_column_double(row, 1) == Self.sampleDate.timeIntervalSince1970)
            #expect((2...7).map { Self.text(row, Int32($0)) } == [
                "dictation", "Classic history fixture", "succeeded", "succeeded", "skipped", "succeeded"
            ])
        }
        #expect(ids == [Self.sampleID.uuidString])
    }

    private func readRows(_ url: URL, sql: String, visit: (OpaquePointer) -> Void) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        // All callers supply temporary files so SQLite can open WAL databases normally.
        let openStatus = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        try #require(openStatus == SQLITE_OK, "Could not open \(url.lastPathComponent)")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        try #require(prepareStatus == SQLITE_OK, Comment(rawValue: String(cString: sqlite3_errmsg(database))))
        let row = try #require(statement)
        var status = sqlite3_step(row)
        while status == SQLITE_ROW {
            visit(row)
            status = sqlite3_step(row)
        }
        try #require(status == SQLITE_DONE)
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
    }

    private func withDefaults(seed: [String: Any], run: (UserDefaults, String) throws -> Void) throws {
        let suite = "typeflux-classic-contract-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setPersistentDomain(seed, forName: suite)
        try run(defaults, suite)
    }

    private func withTemporaryDirectory(run: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(directory)
    }

    private static func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(object as? [String: Any])
    }

    private static func sortedJSON(_ data: Data, prettyPrinted: Bool = true) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys])
    }

    private func checkFixture(_ name: String, data: Data, output: URL?) throws {
        if let output {
            try data.write(to: output.appendingPathComponent(name), options: .atomic)
            return
        }
        let stored = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        #expect(stored == data, "Regenerate \(name) using scripts/generate_classic_contract_fixtures.sh")
    }
}

private struct Column: Equatable {
    let type: String
    let notNull: Bool
}

// Only the decoding shapes and fallback values from v0.4.0 belong here.
private struct ClassicPersona: Decodable {
    enum Kind: String, Decodable { case system, custom }

    let id: UUID
    let name: String
    let prompt: String
    let kind: Kind

    private enum CodingKeys: String, CodingKey { case id, name, prompt, kind }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        prompt = try values.decode(String.self, forKey: .prompt)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .custom
    }
}

private struct ClassicHotkey: Decodable {
    let id: UUID
    let keyCode: Int
    let modifierFlags: UInt
    let pressCount: Int?
    let modifierKeyCodes: [Int]?
}

private struct ClassicVocabularyEntry: Decodable {
    enum Source: String, Decodable { case manual, automatic, claude, codex }

    let id: UUID
    let term: String
    let source: Source
    let createdAt: Date
    let occurrenceCount: Int

    private enum CodingKeys: String, CodingKey { case id, term, source, createdAt, occurrenceCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        term = try values.decode(String.self, forKey: .term)
        source = try values.decode(Source.self, forKey: .source)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        occurrenceCount = try values.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1
    }
}
