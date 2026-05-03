# Typeflux Data Storage Architecture

## Overview

Typeflux uses a layered data storage architecture, employing multiple storage mechanisms based on data type, access frequency, and persistence requirements:

| Storage Type | Purpose | Location | Persistence |
|---------|------|---------|--------|
| SQLite | History records | `~/Library/Application Support/Typeflux/history.sqlite` | ✅ Persistent |
| UserDefaults | App settings, statistics, vocabulary | `~/Library/Preferences/com.typeflux.plist` | ✅ Persistent |
| Filesystem | Audio files | `~/Library/Application Support/Typeflux/` | ✅ Persistent |
| Temporary files | Recorded audio | `~/tmp/typeflux/` | ❌ Temporary |
| In-memory | Error logs, app state | RAM | ❌ Runtime only |

---

## 1. SQLite Database Storage

### 1.1 Architecture Design

History records use **SQLite** as the primary storage engine, implemented via `SQLiteHistoryStore`. Compared to the earlier JSON file storage, SQLite provides better query performance, transaction support, and data integrity.

**Database location:**
```
~/Library/Application Support/Typeflux/history.sqlite
```

### 1.2 Database Schema

```sql
CREATE TABLE IF NOT EXISTS history_records (
    id TEXT PRIMARY KEY NOT NULL,              -- UUID primary key
    date REAL NOT NULL,                         -- Timestamp (timeIntervalSince1970)
    mode TEXT NOT NULL,                         -- Mode: dictation|personaRewrite|editSelection
    audio_file_path TEXT,                       -- Audio file path
    transcript_text TEXT,                       -- Transcribed text
    persona_prompt TEXT,                        -- Persona prompt
    persona_result_text TEXT,                   -- Persona rewrite result
    selection_original_text TEXT,               -- Original selected text
    selection_edited_text TEXT,                 -- Edited text
    recording_duration_seconds REAL,            -- Recording duration
    error_message TEXT,                         -- Error message
    apply_message TEXT,                         -- Apply message
    recording_status TEXT NOT NULL,             -- Recording status
    transcription_status TEXT NOT NULL,         -- Transcription status
    processing_status TEXT NOT NULL,            -- Processing status
    apply_status TEXT NOT NULL                  -- Apply status
);

-- Index optimization
CREATE INDEX IF NOT EXISTS idx_history_records_date ON history_records(date DESC);
```

### 1.3 PRAGMA Configuration

```sql
PRAGMA journal_mode = WAL;       -- Write-Ahead Logging for improved concurrency
PRAGMA synchronous = NORMAL;      -- Balance between performance and data safety
PRAGMA temp_store = MEMORY;       -- Store temporary tables in memory
PRAGMA foreign_keys = ON;         -- Enable foreign key constraints
```

### 1.4 Core Operations

#### Upsert (Insert/Update)
```sql
INSERT INTO history_records (...) VALUES (...)
ON CONFLICT(id) DO UPDATE SET ...;
```

#### Paginated Query
```sql
SELECT * FROM history_records 
WHERE mode LIKE ? OR transcript_text LIKE ? ...
ORDER BY date DESC 
LIMIT ? OFFSET ?;
```

#### Data Cleanup
```sql
DELETE FROM history_records WHERE date < ?;
DELETE FROM history_records;  -- Clear all records
```

### 1.5 Data Migration

Automatic migration from the legacy JSON format:
1. Check whether the database is empty (`rowCount == 0`)
2. Read the `history.json` file
3. Import data in a batch transaction
4. Retain the original file as a backup

### 1.6 Thread Safety

All database operations are executed on a serial `DispatchQueue(label: "history.store.sqlite")`:
- Read operations: use `queue.sync` for synchronous return
- Write operations: use `queue.async` for asynchronous execution

---

## 2. UserDefaults Settings Storage

### 2.1 Architecture Design

Application settings are managed through the `SettingsStore` singleton, backed by `UserDefaults.standard`.

**Storage location:**
```
~/Library/Preferences/com.typeflux.plist
```

### 2.2 Configuration Categories

#### 2.2.1 UI/UX Settings
| Key | Type | Description |
|-----|------|------|
| `ui.language` | String | App language (en/zh) |
| `ui.appearance` | String | Appearance mode (system/light/dark) |

#### 2.2.2 Audio Settings
| Key | Type | Description |
|-----|------|------|
| `audio.input.preferredMicrophoneID` | String | Preferred microphone ID |
| `audio.recording.muteSystemOutput` | Bool | Mute system output during recording |
| `audio.soundEffects.enabled` | Bool | Sound effects toggle |

#### 2.2.3 History Retention Policy
| Key | Type | Description |
|-----|------|------|
| `history.retentionPolicy` | String | Retention policy (never/oneDay/oneWeek/oneMonth/forever) |

**Retention policy mapping:**
- `never` → 0 days
- `oneDay` → 1 day
- `oneWeek` → 7 days
- `oneMonth` → 30 days
- `forever` → nil (never purge)

#### 2.2.4 STT Provider Settings
| Key | Type | Description |
|-----|------|------|
| `stt.provider` | String | Current STT provider |
| `stt.whisper.baseURL` | String | Whisper API base URL |
| `stt.whisper.model` | String | Whisper model |
| `stt.whisper.apiKey` | String | Whisper API key |
| `stt.local.model` | String | Local model type |
| `stt.local.modelIdentifier` | String | Local model identifier |
| `stt.local.downloadSource` | String | Model download source |
| `stt.local.autoSetup` | Bool | Auto-setup local model |
| `stt.multimodal.baseURL` | String | Multimodal LLM base URL |
| `stt.multimodal.model` | String | Multimodal model |
| `stt.multimodal.apiKey` | String | Multimodal API key |
| `stt.alicloud.apiKey` | String | AliCloud API key |
| `stt.doubao.appID` | String | Doubao App ID |
| `stt.doubao.accessToken` | String | Doubao access token |
| `stt.doubao.resourceID` | String | Doubao resource ID |
| `stt.appleSpeech.enabled` | Bool | Apple Speech fallback toggle |

#### 2.2.5 LLM Settings
| Key | Type | Description |
|-----|------|------|
| `llm.provider` | String | LLM provider type |
| `llm.remote.provider` | String | Remote LLM provider |
| `llm.baseURL` | String | LLM base URL |
| `llm.model` | String | LLM model |
| `llm.apiKey` | String | LLM API key |
| `llm.ollama.baseURL` | String | Ollama base URL |
| `llm.ollama.model` | String | Ollama model |
| `llm.ollama.autoSetup` | Bool | Ollama auto-setup |

**Multi-provider configuration key pattern:**
```
llm.remote.{provider}.baseURL
llm.remote.{provider}.model
llm.remote.{provider}.apiKey
```

#### 2.2.6 Persona Settings
| Key | Type | Description |
|-----|------|------|
| `persona.enabled` | Bool | Persona rewrite enabled state |
| `persona.hotkeyAppliesToSelection` | Bool | Whether the persona hotkey applies to selected text |
| `persona.activeID` | String | Currently active persona ID |
| `persona.items` | String (JSON) | Persona list as JSON |

**Persona JSON structure:**
```json
[
  {
    "id": "uuid-string",
    "name": "Professional Assistant",
    "prompt": "Rewrite in professional..."
  }
]
```

#### 2.2.7 Hotkey Settings
| Key | Type | Description |
|-----|------|------|
| `hotkey.activation.json` | String (JSON) | Activation hotkey configuration |
| `hotkey.persona.json` | String (JSON) | Persona hotkey configuration |

**HotkeyBinding JSON structure:**
```json
{
  "id": "uuid-string",
  "keyCode": 54,
  "modifierFlags": 1048576
}
```

### 2.3 Thread Safety

`UserDefaults` is inherently thread-safe, but complex object operations in `SettingsStore` (such as serialization/deserialization of the persona list) are executed on the main thread.

---

## 3. Vocabulary Storage (VocabularyStore)

### 3.1 Architecture Design

User-defined vocabulary entries are managed through `VocabularyStore`, backed by UserDefaults storing JSON-serialized data.

**Storage key:** `vocabulary.entries`

### 3.2 Data Structure

```swift
struct VocabularyEntry: Codable {
    let id: UUID
    let term: String           // Vocabulary term
    let source: VocabularySource  // manual | automatic
    let createdAt: Date
}
```

### 3.3 Core Features

#### Data Deduplication
```swift
private static func deduplicated(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
    // Sort by creation date in descending order
    // Remove empty entries and duplicates (based on normalized term)
}

private static func normalize(_ term: String) -> String {
    term.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

#### Adding Entries
```swift
static func add(term: String, source: VocabularySource = .manual) -> [VocabularyEntry]
```
- Normalize the input (trim leading and trailing whitespace)
- Check for duplicates
- Insert at the beginning of the list
- Persist to UserDefaults

#### Removing Entries
```swift
static func remove(id: UUID) -> [VocabularyEntry]
```

#### Retrieving Active Vocabulary
```swift
static func activeTerms() -> [String]
```

---

## 4. Audio File Storage

### 4.1 Recorded Audio (Temporary Storage)

**Storage location:**
```
~/tmp/typeflux/{uuid}.wav
```

**Implementation class:** `AVFoundationAudioRecorder`

**File format:**
- Format: Linear PCM (WAV)
- Sample rate: Matches the input device
- Channels: Mono
- Bit depth: 16-bit
- Byte order: Little Endian

**Lifecycle:**
1. Recording starts → Create a temporary WAV file
2. Recording ends → Return an `AudioFile` object
3. History record saved → Move to the persistent storage directory
4. Record deleted → Delete the associated audio file

### 4.2 Persistent Audio Storage

**Storage location:**
```
~/Library/Application Support/Typeflux/audio/{uuid}.wav
```

**File management:**
- Managed via `SQLiteHistoryStore` or `FileHistoryStore`
- Deleting a history record cascades to delete the associated audio file
- Periodic cleanup of expired audio files based on the retention policy

### 4.3 Audio Transcoding

**Implementation class:** `AudioFileTranscoder`

Supported format conversions:
- Input: Any format supported by AVAudioFile
- Output: 16-bit PCM WAV

**Temporary transcoding directory:**
```
~/tmp/typeflux-transcoded/{filename}.wav
```

---

## 5. Usage Statistics Storage

### 5.1 Architecture Design

Statistics are managed through the `UsageStatsStore` singleton, backed by UserDefaults.

### 5.2 Statistics Metrics

| Key | Type | Description |
|-----|------|------|
| `stats.totalSessions` | Int | Total number of sessions |
| `stats.successfulSessions` | Int | Number of successful sessions |
| `stats.failedSessions` | Int | Number of failed sessions |
| `stats.totalRecordingSeconds` | Double | User-perceived total time for successful voice sessions (recording duration + post-speech total wait time, in seconds) |
| `stats.estimatedTypingSeconds` | Double | Estimated manual typing time baseline based on final output text (in seconds) |
| `stats.totalCharacters` | Int | Actual output character count the user received; Q&A answers are not counted as "dictation characters"; selection edits preferentially use LCS diff to count only newly added/replaced content relative to the original text; very large text automatically falls back to prefix/suffix heuristics |
| `stats.totalWords` | Int | Output word count, measured consistently with `stats.totalCharacters` |
| `stats.dictationCount` | Int | Number of dictation mode sessions |
| `stats.personaRewriteCount` | Int | Number of persona rewrites |
| `stats.editSelectionCount` | Int | Number of selection edits |
| `stats.askAnswerCount` | Int | Number of voice Q&A sessions |
| `stats.didBackfill` | Bool | Whether data backfill has been completed |
| `stats.calculationVersion` | Int | Current statistics calculation version, used to trigger historical recalculation after algorithm upgrades |

### 5.3 Computed Metrics

```swift
var completionRate: Int          // Success rate %
var totalDictationMinutes: Int   // Total dictation minutes
var savedMinutes: Int            // Estimated time saved
var averagePaceWPM: Int          // Average speaking pace (words per minute)
```

### 5.4 Data Backfill

When statistics are first enabled, data is backfilled from history records. If the calculation version is upgraded, historical metrics are also automatically recalculated based on `stats.calculationVersion`:
```swift
func backfillIfNeeded(from historyStore: HistoryStore)
```

---

## 6. Error Log Storage

### 6.1 Architecture Design

Error logs are managed through the `ErrorLogStore` singleton, stored **in-memory only** and not persisted to disk.

### 6.2 Implementation Details

```swift
final class ErrorLogStore: ObservableObject {
    @Published private(set) var entries: [ErrorLogEntry] = []
    private let maxEntries = 100  // Maximum number of retained entries
}

struct ErrorLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
```

### 6.3 Logging Flow

1. Error occurs → `ErrorLogStore.shared.log(message)`
2. Inserted at the beginning of the in-memory list
3. Old entries are truncated when the limit is exceeded
4. Simultaneously output to `NSLog` for system log collection

---

## 7. App State Storage

### 7.1 Architecture Design

App state is managed through the `AppStateStore` singleton, stored **in-memory only**.

### 7.2 State Enum

```swift
enum AppStatus: Equatable {
    case idle           // Idle
    case recording      // Recording in progress
    case processing     // Processing
    case failed(message: String)  // Failed
}
```

### 7.3 Thread Safety

```swift
func setStatus(_ status: AppStatus) {
    if Thread.isMainThread {
        self.status = status
    } else {
        DispatchQueue.main.async { [weak self] in
            self?.status = status
        }
    }
}
```

---

## 8. Data Storage Access Patterns

### 8.1 Dependency Injection Container

All storage services are managed through `DIContainer`:

```swift
final class DIContainer {
    let appState = AppStateStore()           // In-memory
    let settingsStore = SettingsStore()       // UserDefaults
    let historyStore: HistoryStore            // SQLite
    
    init() {
        historyStore = SQLiteHistoryStore()   // Current implementation
    }
}
```

### 8.2 Data Flow Diagram

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   User Input    │────▶│  WorkflowController │────▶│  AudioRecorder  │
│  (Hotkey/UI)    │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   UI Updates    │◀────│  HistoryStore   │◀────│   Transcriber   │
│  (Overlay/Menu) │     │   (SQLite)      │     │   (STT Service) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         ▲                      │
         └──────────────────────┘
              NotificationCenter
              (.historyStoreDidChange)
```

### 8.3 Change Notification Mechanism

History record changes are broadcast via `NotificationCenter`:

```swift
extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("historyStoreDidChange")
}
```

Trigger conditions:
- After saving a record
- After deleting a record
- After clearing history
- After data cleanup

---

## 9. Data Security and Privacy

### 9.1 Storage Security

| Data Type | Encryption Status | Description |
|---------|---------|------|
| History records | ❌ Not encrypted | Stored in the app sandbox |
| Audio files | ❌ Not encrypted | Stored in the app sandbox |
| API keys | ❌ Not encrypted | Stored in UserDefaults |
| Settings preferences | ❌ Not encrypted | Standard system storage |

### 9.2 Privacy Considerations

- All data is stored **locally** and is never uploaded to the cloud
- History records are retained for **7 days** by default (configurable)
- Temporary audio files are cleaned up periodically
- API keys are only used for local service calls

### 9.3 Data Cleanup Policy

```swift
func purge(olderThanDays days: Int) {
    let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
    // 1. Query expired records
    // 2. Delete associated audio files
    // 3. Delete database records
}
```

---

## 10. Export Functionality

### 10.1 Markdown Export

History records can be exported in Markdown format:

**Export file location:**
```
~/Library/Application Support/Typeflux/history-{timestamp}.md
```

**Markdown structure:**
```markdown
# Typeflux History

## 2024-01-15T10:30:00Z

- Mode: dictation
- Recording: succeeded
- Transcription: succeeded
- Processing: skipped
- Apply: succeeded
- Audio: /path/to/audio.wav

### Transcript

Transcribed text content...

### Persona Result

Rewritten result...

### Error

Error message...
```

### 10.2 Export Implementation

```swift
func exportMarkdown() throws -> URL {
    let records = list()
    // Generate Markdown content
    // Write to file
    return url
}
```

---

## 11. Storage Performance Optimization

### 11.1 SQLite Optimization

- **WAL mode**: Improves concurrent read/write performance
- **Prepared statements**: Reduces SQL parsing overhead
- **Batch transactions**: Used during data migration
- **Index optimization**: Index on the date field

### 11.2 Query Optimization

```swift
// Paginated query
func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord]

// Filtered query
SELECT * FROM history_records 
WHERE mode LIKE ? OR transcript_text LIKE ? ...
ORDER BY date DESC 
LIMIT ? OFFSET ?;
```

### 11.3 Memory Management

- Error logs limited to 100 entries
- Audio files loaded on demand
- Large query results returned in pages

---

## 12. Storage Extensibility

### 12.1 HistoryStore Protocol

```swift
protocol HistoryStore {
    func save(record: HistoryRecord)
    func list() -> [HistoryRecord]
    func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord]
    func record(id: UUID) -> HistoryRecord?
    func delete(id: UUID)
    func purge(olderThanDays days: Int)
    func clear()
    func exportMarkdown() throws -> URL
}
```

Supports multiple implementations:
- `SQLiteHistoryStore` — used in production
- `FileHistoryStore` — legacy JSON implementation (for backward compatibility)

### 12.2 Migration Strategy

```swift
// Migrate from JSON to SQLite
private func migrateLegacyJSONIfNeeded() throws {
    guard try rowCount() == 0 else { return }
    guard let data = try? Data(contentsOf: legacyIndexURL) else { return }
    let records = (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    
    try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
    // Batch import...
    try execute(sql: "COMMIT;")
}
```

---

## 13. Debugging and Monitoring

### 13.1 Network Debug Logging

`NetworkDebugLogger` uses `os.Logger` to record network requests:

```swift
static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "Network")
```

Logged details include:
- Request URL, method, and headers
- Response status code
- Error details

### 13.2 Database Debugging

Errors are recorded via `ErrorLogStore`:

```swift
catch {
    ErrorLogStore.shared.log("History save failed: \(error.localizedDescription)")
}
```

---

## 14. Summary

Typeflux's data storage architecture follows these design principles:

1. **Layered storage**: Selects the most appropriate storage medium based on data characteristics
2. **Protocol abstraction**: Supports multiple storage implementations through the `HistoryStore` protocol
3. **Backward compatibility**: Supports automatic migration from legacy formats
4. **Thread safety**: All storage operations are executed via queues or thread-safe APIs
5. **Performance first**: SQLite + indexes + WAL mode ensure query performance
6. **Privacy first**: All data stored locally with support for automatic cleanup

### Storage Matrix Summary

| Data | Storage | Location | Retention Policy |
|------|------|------|---------|
| History records | SQLite | Application Support | User-configurable (default 7 days) |
| Audio files | Filesystem | Application Support | Linked to history records |
| App settings | UserDefaults | Preferences | Permanent |
| Usage statistics | UserDefaults | Preferences | Permanent |
| Vocabulary | UserDefaults | Preferences | Permanent |
| Error logs | In-memory | RAM | Runtime only (max 100 entries) |
| App state | In-memory | RAM | Runtime only |
