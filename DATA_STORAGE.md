# Typeflux 数据存储架构文档

## 概述

Typeflux 采用分层数据存储架构，根据数据类型、访问频率和持久化需求，使用多种存储机制：

| 存储类型 | 用途 | 存储位置 | 持久化 |
|---------|------|---------|--------|
| SQLite | 历史记录 | `~/Library/Application Support/Typeflux/history.sqlite` | ✅ 持久化 |
| UserDefaults | 应用设置、统计、词汇 | `~/Library/Preferences/com.typeflux.plist` | ✅ 持久化 |
| 文件系统 | 音频文件 | `~/Library/Application Support/Typeflux/` | ✅ 持久化 |
| 临时文件 | 录制音频 | `~/tmp/typeflux/` | ❌ 临时 |
| 内存 | 错误日志、应用状态 | RAM | ❌ 运行时 |

---

## 1. SQLite 数据库存储

### 1.1 架构设计

历史记录采用 **SQLite** 作为首选存储引擎，通过 `SQLiteHistoryStore` 实现。相比早期的 JSON 文件存储，SQLite 提供更好的查询性能、事务支持和数据完整性。

**数据库位置：**
```
~/Library/Application Support/Typeflux/history.sqlite
```

### 1.2 数据库 Schema

```sql
CREATE TABLE IF NOT EXISTS history_records (
    id TEXT PRIMARY KEY NOT NULL,              -- UUID 主键
    date REAL NOT NULL,                         -- 时间戳 (timeIntervalSince1970)
    mode TEXT NOT NULL,                         -- 模式: dictation|personaRewrite|editSelection
    audio_file_path TEXT,                       -- 音频文件路径
    transcript_text TEXT,                       -- 转录文本
    persona_prompt TEXT,                        -- 角色提示词
    persona_result_text TEXT,                   -- 角色重写结果
    selection_original_text TEXT,               -- 选中的原文本
    selection_edited_text TEXT,                 -- 编辑后的文本
    recording_duration_seconds REAL,            -- 录音时长
    error_message TEXT,                         -- 错误信息
    apply_message TEXT,                         -- 应用消息
    recording_status TEXT NOT NULL,             -- 录音状态
    transcription_status TEXT NOT NULL,         -- 转录状态
    processing_status TEXT NOT NULL,            -- 处理状态
    apply_status TEXT NOT NULL                  -- 应用状态
);

-- 索引优化
CREATE INDEX IF NOT EXISTS idx_history_records_date ON history_records(date DESC);
```

### 1.3 PRAGMA 配置

```sql
PRAGMA journal_mode = WAL;       -- Write-Ahead Logging 提高并发性能
PRAGMA synchronous = NORMAL;      -- 平衡性能和数据安全
PRAGMA temp_store = MEMORY;       -- 临时表存储在内存
PRAGMA foreign_keys = ON;         -- 启用外键约束
```

### 1.4 核心操作

#### Upsert (插入/更新)
```sql
INSERT INTO history_records (...) VALUES (...)
ON CONFLICT(id) DO UPDATE SET ...;
```

#### 分页查询
```sql
SELECT * FROM history_records 
WHERE mode LIKE ? OR transcript_text LIKE ? ...
ORDER BY date DESC 
LIMIT ? OFFSET ?;
```

#### 数据清理
```sql
DELETE FROM history_records WHERE date < ?;
DELETE FROM history_records;  -- 清空所有
```

### 1.5 数据迁移

从旧版 JSON 格式自动迁移：
1. 检查数据库是否为空 (`rowCount == 0`)
2. 读取 `history.json` 文件
3. 使用事务批量导入数据
4. 保留原文件作为备份

### 1.6 线程安全

所有数据库操作通过 `DispatchQueue(label: "history.store.sqlite")` 串行队列执行：
- 读操作：使用 `queue.sync` 同步返回
- 写操作：使用 `queue.async` 异步执行

---

## 2. UserDefaults 设置存储

### 2.1 架构设计

应用设置通过 `SettingsStore` 单例管理，底层使用 `UserDefaults.standard`。

**存储位置：**
```
~/Library/Preferences/com.typeflux.plist
```

### 2.2 配置分类

#### 2.2.1 UI/UX 设置
| Key | 类型 | 说明 |
|-----|------|------|
| `ui.language` | String | 应用语言 (en/zh) |
| `ui.appearance` | String | 外观模式 (system/light/dark) |

#### 2.2.2 音频设置
| Key | 类型 | 说明 |
|-----|------|------|
| `audio.input.preferredMicrophoneID` | String | 首选麦克风 ID |
| `audio.recording.muteSystemOutput` | Bool | 录音时静音系统输出 |
| `audio.soundEffects.enabled` | Bool | 音效开关 |

#### 2.2.3 历史记录策略
| Key | 类型 | 说明 |
|-----|------|------|
| `history.retentionPolicy` | String | 保留策略 (never/oneDay/oneWeek/oneMonth/forever) |

**保留策略映射：**
- `never` → 0 天
- `oneDay` → 1 天
- `oneWeek` → 7 天
- `oneMonth` → 30 天
- `forever` → nil (不清理)

#### 2.2.4 STT 提供商设置
| Key | 类型 | 说明 |
|-----|------|------|
| `stt.provider` | String | 当前 STT 提供商 |
| `stt.whisper.baseURL` | String | Whisper API 基础 URL |
| `stt.whisper.model` | String | Whisper 模型 |
| `stt.whisper.apiKey` | String | Whisper API 密钥 |
| `stt.local.model` | String | 本地模型类型 |
| `stt.local.modelIdentifier` | String | 本地模型标识符 |
| `stt.local.downloadSource` | String | 模型下载源 |
| `stt.local.autoSetup` | Bool | 自动设置本地模型 |
| `stt.multimodal.baseURL` | String | 多模态 LLM 基础 URL |
| `stt.multimodal.model` | String | 多模态模型 |
| `stt.multimodal.apiKey` | String | 多模态 API 密钥 |
| `stt.alicloud.apiKey` | String | 阿里云 API 密钥 |
| `stt.doubao.appID` | String | 豆包 App ID |
| `stt.doubao.accessToken` | String | 豆包访问令牌 |
| `stt.doubao.resourceID` | String | 豆包资源 ID |
| `stt.appleSpeech.enabled` | Bool | Apple Speech 降级开关 |

#### 2.2.5 LLM 设置
| Key | 类型 | 说明 |
|-----|------|------|
| `llm.provider` | String | LLM 提供商类型 |
| `llm.remote.provider` | String | 远程 LLM 提供商 |
| `llm.baseURL` | String | LLM 基础 URL |
| `llm.model` | String | LLM 模型 |
| `llm.apiKey` | String | LLM API 密钥 |
| `llm.ollama.baseURL` | String | Ollama 基础 URL |
| `llm.ollama.model` | String | Ollama 模型 |
| `llm.ollama.autoSetup` | Bool | Ollama 自动设置 |

**多提供商配置键名模式：**
```
llm.remote.{provider}.baseURL
llm.remote.{provider}.model
llm.remote.{provider}.apiKey
```

#### 2.2.6 Persona 设置
| Key | 类型 | 说明 |
|-----|------|------|
| `persona.enabled` | Bool | 角色重写启用状态 |
| `persona.hotkeyAppliesToSelection` | Bool | Persona 热键应用于选中文本 |
| `persona.activeID` | String | 当前激活的角色 ID |
| `persona.items` | String (JSON) | 角色列表 JSON |

**Persona JSON 结构：**
```json
[
  {
    "id": "uuid-string",
    "name": "Professional Assistant",
    "prompt": "Rewrite in professional..."
  }
]
```

#### 2.2.7 热键设置
| Key | 类型 | 说明 |
|-----|------|------|
| `hotkey.activation.json` | String (JSON) | 激活热键配置 |
| `hotkey.persona.json` | String (JSON) | Persona 热键配置 |

**HotkeyBinding JSON 结构：**
```json
{
  "id": "uuid-string",
  "keyCode": 54,
  "modifierFlags": 1048576
}
```

### 2.3 线程安全

UserDefaults 本身是线程安全的，但 `SettingsStore` 中的复杂对象（如 Persona 列表的序列化/反序列化）在主线程执行。

---

## 3. 词汇表存储 (VocabularyStore)

### 3.1 架构设计

用户自定义词汇通过 `VocabularyStore` 管理，底层使用 UserDefaults 存储 JSON 序列化数据。

**存储键名：** `vocabulary.entries`

### 3.2 数据结构

```swift
struct VocabularyEntry: Codable {
    let id: UUID
    let term: String           // 词汇条目
    let source: VocabularySource  // manual | automatic
    let createdAt: Date
}
```

### 3.3 核心功能

#### 数据去重
```swift
private static func deduplicated(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
    // 按创建时间降序排序
    // 去除空项和重复项（基于标准化后的 term）
}

private static func normalize(_ term: String) -> String {
    term.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

#### 添加条目
```swift
static func add(term: String, source: VocabularySource = .manual) -> [VocabularyEntry]
```
- 标准化输入（去除首尾空格）
- 检查重复
- 插入到列表头部
- 持久化到 UserDefaults

#### 删除条目
```swift
static func remove(id: UUID) -> [VocabularyEntry]
```

#### 获取活跃词汇
```swift
static func activeTerms() -> [String]
```

---

## 4. 音频文件存储

### 4.1 录制音频 (临时存储)

**存储位置：**
```
~/tmp/typeflux/{uuid}.wav
```

**实现类：** `AVFoundationAudioRecorder`

**文件格式：**
- 格式: Linear PCM (WAV)
- 采样率: 与输入设备相同
- 声道: 单声道 (Mono)
- 位深度: 16-bit
- 字节序: Little Endian

**生命周期：**
1. 录音开始 → 创建临时 WAV 文件
2. 录音结束 → 返回 `AudioFile` 对象
3. 历史记录保存 → 移动到持久化目录
4. 记录删除 → 删除关联音频文件

### 4.2 持久化音频存储

**存储位置：**
```
~/Library/Application Support/Typeflux/audio/{uuid}.wav
```

**文件管理：**
- 通过 `SQLiteHistoryStore` 或 `FileHistoryStore` 管理
- 删除历史记录时级联删除音频文件
- 定期清理过期音频（基于保留策略）

### 4.3 音频转码

**实现类：** `AudioFileTranscoder`

支持格式转换：
- 输入：任意 AVAudioFile 支持的格式
- 输出：16-bit PCM WAV

**临时转码目录：**
```
~/tmp/typeflux-transcoded/{filename}.wav
```

---

## 5. 使用统计存储

### 5.1 架构设计

统计信息通过 `UsageStatsStore` 单例管理，底层使用 UserDefaults。

### 5.2 统计指标

| Key | 类型 | 说明 |
|-----|------|------|
| `stats.totalSessions` | Int | 总会话数 |
| `stats.successfulSessions` | Int | 成功会话数 |
| `stats.failedSessions` | Int | 失败会话数 |
| `stats.totalRecordingSeconds` | Double | 成功语音会话的用户感知总耗时（录音时长 + 说完后的整体等待时长，秒） |
| `stats.estimatedTypingSeconds` | Double | 以最终输出文本估算的手动输入耗时基线（秒） |
| `stats.totalCharacters` | Int | 用户最终实际获得的输出字符数；问答答案不计入“听写字符数”，选区编辑优先用 LCS diff 只计入相对原文的新增/替换内容，超大文本自动降级为前后缀启发式 |
| `stats.totalWords` | Int | 与 `stats.totalCharacters` 同口径的输出词数 |
| `stats.dictationCount` | Int | 听写模式次数 |
| `stats.personaRewriteCount` | Int | 角色重写次数 |
| `stats.editSelectionCount` | Int | 选中文本编辑次数 |
| `stats.askAnswerCount` | Int | 语音问答次数 |
| `stats.didBackfill` | Bool | 是否已完成数据回填 |
| `stats.calculationVersion` | Int | 当前统计口径版本，用于算法升级后触发历史重算 |

### 5.3 计算指标

```swift
var completionRate: Int          // 成功率 %
var totalDictationMinutes: Int   // 总听写分钟数
var savedMinutes: Int            // 节省时间估算
var averagePaceWPM: Int          // 平均语速（词/分钟）
```

### 5.4 数据回填

首次启用统计时会从历史记录回填数据；如果统计口径升级，也会根据 `stats.calculationVersion` 自动重算历史指标：
```swift
func backfillIfNeeded(from historyStore: HistoryStore)
```

---

## 6. 错误日志存储

### 6.1 架构设计

错误日志通过 `ErrorLogStore` 单例管理，**仅内存存储**，不持久化到磁盘。

### 6.2 实现细节

```swift
final class ErrorLogStore: ObservableObject {
    @Published private(set) var entries: [ErrorLogEntry] = []
    private let maxEntries = 100  // 最大保留条目数
}

struct ErrorLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
```

### 6.3 日志流程

1. 错误发生 → `ErrorLogStore.shared.log(message)`
2. 插入到内存列表头部
3. 超出限制时截断旧条目
4. 同时输出到 `NSLog` 供系统日志收集

---

## 7. 应用状态存储

### 7.1 架构设计

应用状态通过 `AppStateStore` 单例管理，**仅内存存储**。

### 7.2 状态枚举

```swift
enum AppStatus: Equatable {
    case idle           // 空闲
    case recording      // 录音中
    case processing     // 处理中
    case failed(message: String)  // 失败
}
```

### 7.3 线程安全

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

## 8. 数据存储访问模式

### 8.1 依赖注入容器

所有存储服务通过 `DIContainer` 统一管理：

```swift
final class DIContainer {
    let appState = AppStateStore()           // 内存
    let settingsStore = SettingsStore()       // UserDefaults
    let historyStore: HistoryStore            // SQLite
    
    init() {
        historyStore = SQLiteHistoryStore()   // 当前实现
    }
}
```

### 8.2 数据流图

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   用户交互       │────▶│  WorkflowController │────▶│  AudioRecorder  │
│  (Hotkey/UI)    │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   UI 更新        │◀────│  HistoryStore   │◀────│   Transcriber   │
│  (Overlay/Menu) │     │   (SQLite)      │     │   (STT Service) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         ▲                      │
         └──────────────────────┘
              NotificationCenter
              (.historyStoreDidChange)
```

### 8.3 变更通知机制

历史记录变更通过 `NotificationCenter` 广播：

```swift
extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("historyStoreDidChange")
}
```

触发时机：
- 保存记录后
- 删除记录后
- 清空历史后
- 数据清理后

---

## 9. 数据安全与隐私

### 9.1 存储安全

| 数据类型 | 加密状态 | 说明 |
|---------|---------|------|
| 历史记录 | ❌ 未加密 | 存储在应用沙盒 |
| 音频文件 | ❌ 未加密 | 存储在应用沙盒 |
| API 密钥 | ❌ 未加密 | 存储在 UserDefaults |
| 设置偏好 | ❌ 未加密 | 标准系统存储 |

### 9.2 隐私考虑

- 所有数据**本地存储**，不上传云端
- 历史记录默认保留 **7 天**（可配置）
- 临时音频文件定期清理
- API 密钥仅用于本地服务调用

### 9.3 数据清理策略

```swift
func purge(olderThanDays days: Int) {
    let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
    // 1. 查询过期记录
    // 2. 删除关联音频文件
    // 3. 删除数据库记录
}
```

---

## 10. 导出功能

### 10.1 Markdown 导出

历史记录支持导出为 Markdown 格式：

**导出文件位置：**
```
~/Library/Application Support/Typeflux/history-{timestamp}.md
```

**Markdown 结构：**
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

转录文本内容...

### Persona Result

重写结果...

### Error

错误信息...
```

### 10.2 导出实现

```swift
func exportMarkdown() throws -> URL {
    let records = list()
    // 生成 Markdown 内容
    // 写入文件
    return url
}
```

---

## 11. 存储性能优化

### 11.1 SQLite 优化

- **WAL 模式**：提高并发读写性能
- **预编译语句**：减少 SQL 解析开销
- **批量事务**：数据迁移时使用事务
- **索引优化**：按日期字段建立索引

### 11.2 查询优化

```swift
// 分页查询
func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord]

// 带过滤的查询
SELECT * FROM history_records 
WHERE mode LIKE ? OR transcript_text LIKE ? ...
ORDER BY date DESC 
LIMIT ? OFFSET ?;
```

### 11.3 内存管理

- 错误日志限制 100 条
- 音频文件按需加载
- 大型查询结果分页返回

---

## 12. 存储扩展性

### 12.1 HistoryStore 协议

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

支持多种实现：
- `SQLiteHistoryStore` - 生产环境使用
- `FileHistoryStore` - 旧版 JSON 实现（向后兼容）

### 12.2 迁移策略

```swift
// 从 JSON 迁移到 SQLite
private func migrateLegacyJSONIfNeeded() throws {
    guard try rowCount() == 0 else { return }
    guard let data = try? Data(contentsOf: legacyIndexURL) else { return }
    let records = (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    
    try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
    // 批量导入...
    try execute(sql: "COMMIT;")
}
```

---

## 13. 调试与监控

### 13.1 网络调试日志

`NetworkDebugLogger` 使用 `os.Logger` 记录网络请求：

```swift
static let logger = Logger(subsystem: "dev.typeflux", category: "Network")
```

日志包含：
- 请求 URL、方法、Headers
- 响应状态码
- 错误详情

### 13.2 数据库调试

错误通过 `ErrorLogStore` 记录：

```swift
catch {
    ErrorLogStore.shared.log("History save failed: \(error.localizedDescription)")
}
```

---

## 14. 总结

Typeflux 的数据存储架构遵循以下设计原则：

1. **分层存储**：根据数据特性选择最合适的存储介质
2. **协议抽象**：通过 `HistoryStore` 协议支持多种存储实现
3. **向后兼容**：支持从旧格式自动迁移
4. **线程安全**：所有存储操作通过队列或线程安全 API 执行
5. **性能优先**：SQLite + 索引 + WAL 模式确保查询性能
6. **隐私优先**：所有数据本地存储，支持自动清理

### 存储矩阵总结

| 数据 | 存储 | 位置 | 保留策略 |
|------|------|------|---------|
| 历史记录 | SQLite | Application Support | 用户配置（默认7天） |
| 音频文件 | 文件系统 | Application Support | 与历史记录联动 |
| 应用设置 | UserDefaults | Preferences | 永久 |
| 使用统计 | UserDefaults | Preferences | 永久 |
| 词汇表 | UserDefaults | Preferences | 永久 |
| 错误日志 | 内存 | RAM | 运行时（最多100条） |
| 应用状态 | 内存 | RAM | 运行时 |
