# 配置设计

## 配置项（建议）

### Hotkey
- `useFnAsPrimary: Bool`：默认 true
- `customHotkeys: [HotkeyBinding]`：用户自定义组合键集合
- 立即生效：设置页写入后触发 `HotkeyService.updateBindings(...)`

### STT
- `stt.provider: enum`：`whisperAPI` / `appleSpeech`
- Whisper（OpenAI-compatible transcriptions）
  - `stt.whisper.baseURL`
  - `stt.whisper.apiKey`
  - `stt.whisper.model`
- Apple Speech
  - `stt.appleSpeech.enabled`

### LLM
- `llm.provider: enum`：`openAICompatible` / `ollama`
- OpenAI-compatible ChatCompletions
  - `llm.baseURL`
  - `llm.apiKey`
  - `llm.model`
- Ollama（本地模型）
  - `llm.ollama.baseURL`
  - `llm.ollama.model`
  - `llm.ollama.autoSetup`

### Personas
- `persona.enabled: Bool`
- `persona.activeID: String`
- `persona.items: JSON<[PersonaProfile]>`

## Provider 路由策略
- 当 `stt.provider == whisperAPI` 且 Whisper 配置完整：使用 Whisper API
- 当 `stt.provider == whisperAPI` 但配置不完整且允许 fallback：使用 Apple Speech
- 当 `stt.provider == appleSpeech`：直接使用 Apple Speech
- 当 `llm.provider == openAICompatible`：使用远程或自建 OpenAI-compatible Chat API
- 当 `llm.provider == ollama`：自动检查本地 Ollama 服务、按需拉起服务并拉取模型

## 人设处理策略
- 若用户有选中文本：语音内容作为编辑指令，和激活的人设一起作用于选中文本
- 若用户未选中文本但激活了人设：把 STT 结果送给 LLM 按人设进行二次改写
- 若用户未激活人设：直接插入转写结果

## 存储建议
- UserDefaults：
  - provider、baseURL、model、开关、快捷键列表、人设 JSON
- Keychain：
  - STT/LLM API Key（当前实现仍在 UserDefaults，可后续迁移）

## 变更通知
- `SettingsStore` 在配置变化时发送通知（例如 Combine Publisher 或 NotificationCenter）
- 订阅方：
  - `HotkeyService`（立即更新绑定）
  - `STTRouter`（更新 Provider）
  - `LLMService`（更新 baseURL/model）
