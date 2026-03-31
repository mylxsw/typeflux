# Typeflux 本地模型 Swift 化重构需求文档

**版本**: v1.0  
**日期**: 2026-03-31  
**状态**: 待评审  

---

## 1. 项目背景与目标

### 1.1 现状问题

当前 Typeflux 的本地语音转文本功能依赖 Python 运行时环境，存在以下问题：

1. **新用户体验差**：macOS 12.3+ 不再预装 Python 3，用户首次使用需等待数分钟安装 Python 环境和依赖包
2. **打包分发困难**：无法提供开箱即用的 .app 安装包，用户必须先配置环境
3. **维护成本高**：需要维护 Python 虚拟环境、依赖版本兼容性、模型下载脚本
4. **性能损耗**：HTTP 进程间通信引入额外延迟

### 1.2 项目目标

| 目标 | 描述 |
|------|------|
| **核心目标** | 完全移除 Python 依赖，所有本地模型推理使用 Swift/原生框架实现 |
| **用户体验** | 实现开箱即用，首次启动无需等待环境配置 |
| **性能提升** | 利用 Apple Silicon 原生加速（ANE/GPU），降低延迟和内存占用 |
| **代码统一** | 统一为 Swift 代码库，降低维护成本 |

---

## 2. 技术方案总览

### 2.1 架构变更

```
当前架构（Python 混合）                    目标架构（纯 Swift）
┌─────────────────────────┐                ┌─────────────────────────┐
│   Typeflux (Swift)      │                │   Typeflux (Swift)      │
│   ├─ LocalModelTranscriber           │   ├─ WhisperKitTranscriber       │
│   ├─ LocalSTTServiceManager          │   ├─ SenseVoiceCoreMLTranscriber │
│   │   ├─ HTTP Client    │                │   ├─ Qwen3ASRMLXTranscriber      │
│   │   └─ Process Runner │                │   └─ AppleSpeechTranscriber      │
│   └─ ...                │                │                         │
└───────────┬─────────────┘                └─────────────────────────┘
            │ HTTP
            ▼
┌─────────────────────────┐
│  local_stt_server.py    │
│  (Python FastAPI)       │
│  ├─ openai-whisper      │
│  ├─ funasr/SenseVoice   │
│  └─ qwen-asr           │
└─────────────────────────┘
```

### 2.2 技术选型对比

| 模型 | 当前方案 | 目标方案 | 选型理由 |
|------|---------|---------|---------|
| **Whisper** | Python + openai-whisper | **WhisperKit** (Core ML) | Apple 平台最佳实践，社区成熟，自动利用 ANE/GPU |
| **SenseVoice** | Python + FunASR | **Core ML 转换版** | 已有社区 Core ML 模型，推理速度快，无依赖 |
| **Qwen3-ASR** | Python + qwen-asr | **MLX Swift** | 纯 Swift 实现，Metal GPU 加速，API 原生 |

---

## 3. 详细实施方案

### 3.1 Whisper 迁移方案

#### 3.1.1 技术选型：WhisperKit

- **仓库**: https://github.com/argmaxinc/WhisperKit
- **许可证**: MIT
- **Swift 版本**: 5.9+
- **平台要求**: macOS 13+, iOS 16+, Apple Silicon

#### 3.1.2 集成步骤

1. **添加依赖**（Package.swift）
```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0")
]
```

2. **模型管理**
   - 使用 WhisperKit 内置的模型下载器
   - 默认使用 `small` 模型（约 500MB）
   - 模型缓存路径：`~/Library/Caches/Typeflux/WhisperKit/`

3. **核心实现类**
```swift
final class WhisperKitTranscriber: Transcriber {
    private var whisperKit: WhisperKit?
    
    func setup() async throws {
        whisperKit = try await WhisperKit(model: "small")
    }
    
    func transcribe(audioFile: AudioFile) async throws -> String {
        let result = try await whisperKit.transcribe(audioPath: audioFile.fileURL.path)
        return result.text
    }
}
```

#### 3.1.3 验收标准

- [ ] WhisperKit 成功集成到项目
- [ ] small 模型推理 RTF < 0.1（比 Python 版本快 30% 以上）
- [ ] 内存占用 < 1.5GB
- [ ] 支持中英文识别

---

### 3.2 SenseVoice 迁移方案

#### 3.2.1 技术选型：Core ML 转换模型

- **来源**: HuggingFace `mefengl/SenseVoiceSmall-coreml`
- **格式**: `.mlmodelc`（已编译 Core ML 模型）
- **大小**: 约 300-400MB
- **支持语言**: 中文、粤语、英语、日语、韩语

#### 3.2.2 集成步骤

1. **模型获取**
   - 下载地址：https://huggingface.co/mefengl/SenseVoiceSmall-coreml
   - 首次运行时自动下载并缓存
   - 备用：自建 CDN 托管转换后的模型

2. **Core ML 集成**
```swift
import CoreML

final class SenseVoiceCoreMLTranscriber: Transcriber {
    private var model: MLModel?
    
    func setup() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // 使用 ANE + GPU + CPU
        model = try await SenseVoiceSmall.load(configuration: config)
    }
    
    func transcribe(audioFile: AudioFile) async throws -> String {
        // 音频预处理（转 Mel 频谱）
        // Core ML 推理
        // 后处理（ITN、标点恢复）
    }
}
```

3. **音频预处理**
   - 使用 Accelerate 框架进行音频处理
   - 转换为 16kHz 单声道
   - 提取 80 维 log-Mel 特征

#### 3.2.3 备选方案：ONNX Runtime

如果 Core ML 版本精度不达标，使用 ONNX Runtime：

```swift
// 使用 ONNX Runtime Swift
import onnxruntime

// 加载模型
let session = try ORTSession(modelPath: senseVoiceONNXPath)

// 运行推理（自动使用 Core ML Execution Provider）
let outputs = try session.run(withInputs: ["input": melFeatures])
```

#### 3.2.4 验收标准

- [ ] 中文识别准确率 ≥ Python 版本（WER < 5%）
- [ ] 推理 RTF < 0.08
- [ ] 支持情感识别（喜怒哀乐标签）
- [ ] 支持音频事件检测

---

### 3.3 Qwen3-ASR 迁移方案

#### 3.3.1 技术选型：MLX Swift

- **推荐库**: `speech-swift`（原 qwen3-asr-swift）
- **仓库**: https://github.com/soniqo/speech-swift
- **技术栈**: MLX Swift（Apple 原生深度学习框架）
- **平台要求**: macOS 14+（Sonoma）, Apple Silicon

#### 3.3.2 集成步骤

1. **添加依赖**
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/soniqo/speech-swift.git", from: "1.0.0")
]
```

2. **核心实现**
```swift
import Qwen3ASR

final class Qwen3ASRMLXTranscriber: Transcriber {
    private var model: Qwen3ASR?
    
    func setup() async throws {
        // 自动下载模型（mlx-community/Qwen3-ASR-0.6B-bf16）
        model = try await Qwen3ASR.from_pretrained("mlx-community/Qwen3-ASR-0.6B-bf16")
    }
    
    func transcribe(audioFile: AudioFile) async throws -> String {
        let result = try await model?.transcribe(audio: audioFile.fileURL.path)
        return result?.text ?? ""
    }
}
```

3. **模型配置**
   - 默认模型：Qwen3-ASR-0.6B
   - 可选模型：Qwen3-ASR-1.7B（更高精度，更慢）
   - 量化：支持 4-bit/8-bit 量化加速

#### 3.3.3 性能基准

| 指标 | 目标值 | 备注 |
|------|-------|------|
| RTF | < 0.06 | M2 Max 基准 |
| 内存占用 | ~2.2GB | FP16 模型 |
| 支持语言 | 52 种 | 含中文方言 |
| 首次下载 | ~500MB | 0.6B 模型 |

#### 3.3.4 验收标准

- [ ] 中文识别准确率 ≥ 官方 PyTorch 版本
- [ ] 推理速度比 Python 版本快 20% 以上
- [ ] 支持长音频（> 30秒）自动分块处理
- [ ] 支持时间戳对齐（可选功能）

---

## 4. 架构重构设计

### 4.1 新的 STT 路由架构

```swift
// MARK: - 统一接口
protocol Transcriber: Sendable {
    func transcribe(audioFile: AudioFile) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String
}

// MARK: - 本地模型枚举
enum LocalSTTProvider: String, CaseIterable {
    case whisperKit       // 基于 Core ML 的 Whisper
    case senseVoiceCoreML // 基于 Core ML 的 SenseVoice
    case qwen3ASRMLX      // 基于 MLX 的 Qwen3-ASR
    
    var displayName: String {
        switch self {
        case .whisperKit:       return "Whisper (本地)"
        case .senseVoiceCoreML: return "SenseVoice (本地)"
        case .qwen3ASRMLX:      return "Qwen3-ASR (本地)"
        }
    }
}

// MARK: - 工厂模式创建 Transcriber
struct LocalTranscriberFactory {
    static func create(
        provider: LocalSTTProvider,
        settings: SettingsStore
    ) -> Transcriber {
        switch provider {
        case .whisperKit:
            return WhisperKitTranscriber(settings: settings)
        case .senseVoiceCoreML:
            return SenseVoiceCoreMLTranscriber(settings: settings)
        case .qwen3ASRMLX:
            return Qwen3ASRMLXTranscriber(settings: settings)
        }
    }
}
```

### 4.2 模型管理器设计

```swift
final class LocalModelManager: ObservableObject {
    // 模型下载状态
    @Published var downloadProgress: [LocalSTTProvider: Double] = [:]
    @Published var modelStates: [LocalSTTProvider: ModelState] = [:]
    
    // 检查模型是否已下载
    func isModelReady(_ provider: LocalSTTProvider) -> Bool
    
    // 下载/更新模型
    func downloadModel(_ provider: LocalSTTProvider) async throws
    
    // 删除模型释放空间
    func deleteModel(_ provider: LocalSTTProvider) throws
    
    // 获取模型大小
    func modelSize(_ provider: LocalSTTProvider) -> UInt64?
}

enum ModelState {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case error(Error)
}
```

---

## 5. 用户界面变更

### 5.1 设置界面调整

**本地模型设置页面重构：**

```
┌─────────────────────────────────────────────────────┐
│  本地模型设置                                        │
├─────────────────────────────────────────────────────┤
│  选择模型提供商                                      │
│  ○ Whisper (本地)           [已下载] [删除]         │
│    └─ 模型大小: 500MB                               │
│    └─ 支持语言: 100+                                │
│                                                      │
│  ○ SenseVoice (本地)        [未下载] [下载]         │
│    └─ 模型大小: 350MB                               │
│    └─ 支持语言: 中/粤/英/日/韩                       │
│    └─ 特色: 情感识别、音频事件检测                   │
│                                                      │
│  ○ Qwen3-ASR (本地)         [更新]                 │
│    └─ 模型大小: 500MB (0.6B) / 1.2GB (1.7B)        │
│    └─ 支持语言: 52种                                │
│    └─ 特色: 中文方言支持                            │
├─────────────────────────────────────────────────────┤
│  [高级设置]                                          │
│  • 模型精度: 默认 / FP16 / INT8 / INT4              │
│  • 计算设备: 自动 / ANE / GPU / CPU                 │
└─────────────────────────────────────────────────────┘
```

### 5.2 首次使用引导

**新用户流程：**

1. 用户选择本地模型作为 STT 提供商
2. 如果模型未下载，弹出引导界面：
   - 显示模型大小、下载时间预估
   - 提供"立即下载"和"稍后下载"选项
3. 下载完成后自动启用
4. 无需重启应用

---

## 6. 数据迁移方案

### 6.1 用户设置迁移

| 旧设置项 | 新设置项 | 迁移策略 |
|---------|---------|---------|
| `stt.local.model` = `whisperLocal` | `stt.local.provider` = `whisperKit` | 自动迁移，保留 Whisper 选择 |
| `stt.local.model` = `senseVoiceSmall` | `stt.local.provider` = `senseVoiceCoreML` | 自动迁移 |
| `stt.local.model` = `qwen3ASR` | `stt.local.provider` = `qwen3ASRMLX` | 自动迁移 |
| `stt.local.modelIdentifier` | 删除 | 使用各模型默认配置 |

### 6.2 旧数据清理

- 检测旧版 Python 虚拟环境：`~/Library/Application Support/Typeflux/STT/Runtime/`
- 提示用户是否清理（可释放 2-5GB 空间）
- 提供一键清理功能

---

## 7. 开发计划与里程碑

### Phase 1: 基础设施（Week 1-2）

- [ ] 搭建新的 `Transcriber` 协议和工厂类
- [ ] 实现 `LocalModelManager` 模型管理器
- [ ] 重构 `SettingsStore`，支持新的本地模型配置
- [ ] 编写模型下载、缓存、清理工具类

### Phase 2: WhisperKit 集成（Week 3-4）

- [ ] 集成 WhisperKit Swift Package
- [ ] 实现 `WhisperKitTranscriber`
- [ ] 模型下载与缓存逻辑
- [ ] 性能测试与调优
- [ ] 单元测试

### Phase 3: Qwen3-ASR MLX 集成（Week 5-6）

- [ ] 评估 `speech-swift` 库稳定性
- [ ] 实现 `Qwen3ASRMLXTranscriber`
- [ ] 长音频分块处理逻辑
- [ ] 精度对比测试（vs Python 版本）
- [ ] 内存和性能测试

### Phase 4: SenseVoice Core ML 集成（Week 7-8）

- [ ] 验证 Core ML 模型精度
- [ ] 实现音频预处理（Mel 特征提取）
- [ ] 实现 `SenseVoiceCoreMLTranscriber`
- [ ] 如精度不达标，实施 ONNX Runtime 备选方案
- [ ] 情感识别、音频事件检测功能验证

### Phase 5: 整合与优化（Week 9-10）

- [ ] 统一三种模型的错误处理
- [ ] 优化首次使用体验（下载引导）
- [ ] 设置界面重构
- [ ] 数据迁移逻辑
- [ ] 旧 Python 环境清理功能

### Phase 6: 测试与发布（Week 11-12）

- [ ] 端到端测试（三种模型）
- [ ] 性能基准测试
- [ ] 用户验收测试（UAT）
- [ ] 文档更新
- [ ] 发布说明编写

---

## 8. 风险评估与应对

| 风险 | 影响 | 概率 | 应对策略 |
|------|------|------|---------|
| **SenseVoice Core ML 精度不达标** | 高 | 中 | 使用 ONNX Runtime 备选方案 |
| **speech-swift 库维护不稳定** | 高 | 低 | 准备 mlx-qwen3-asr 备选（纯 Python MLX） |
| **WhisperKit 模型下载慢** | 中 | 中 | 搭建国内 CDN 镜像或预打包 |
| **MLX 仅支持 macOS 14+** | 中 | 高 | 为 macOS 13 用户提供 WhisperKit 作为降级方案 |
| **Core ML 模型文件过大** | 低 | 中 | 提供 INT8 量化版本，减小 50% 体积 |
| **开发周期超预期** | 中 | 中 | Phase 1-2 优先，确保 WhisperKit 可用；SenseVoice/Qwen3 可迭代 |

---

## 9. 性能基准

### 9.1 目标性能指标

| 模型 | 推理 RTF | 内存占用 | 首次冷启动 | 模型大小 |
|------|---------|---------|-----------|---------|
| Whisper (small) | < 0.08 | < 1.2GB | < 2s | ~500MB |
| SenseVoice (small) | < 0.06 | < 1.0GB | < 1.5s | ~350MB |
| Qwen3-ASR (0.6B) | < 0.06 | < 2.5GB | < 2s | ~500MB |

### 9.2 对比当前 Python 方案

| 指标 | Python 方案 | Swift 目标 | 提升幅度 |
|------|------------|-----------|---------|
| 首次启动时间 | 3-5 分钟 | < 10 秒 | **30-50x** |
| 内存占用 | 2-5GB | 1-2.5GB | **50%** |
| 推理延迟 | 基准 | 快 20-40% | **20-40%** |
| 打包体积 | 需 Python 环境 | 单 .app | **极大简化** |

---

## 10. 验收标准

### 10.1 功能验收

- [ ] 三种本地模型（WhisperKit、SenseVoice、Qwen3-ASR）均可正常识别语音
- [ ] 模型下载、更新、删除功能正常
- [ ] 设置界面可切换不同本地模型
- [ ] 旧用户设置自动迁移
- [ ] 旧 Python 环境可一键清理

### 10.2 性能验收

- [ ] 所有本地模型 RTF < 0.1
- [ ] 内存占用比 Python 版本降低 30% 以上
- [ ] 首次启动无需等待 Python 环境安装

### 10.3 用户体验验收

- [ ] 新用户下载 App 后可直接使用本地模型（只需下载模型文件）
- [ ] 模型下载过程有进度提示
- [ ] 错误提示清晰（网络问题、磁盘空间不足等）

---

## 11. 附录

### 11.1 参考资源

1. **WhisperKit**
   - GitHub: https://github.com/argmaxinc/WhisperKit
   - 文档: https://argmaxinc.github.io/WhisperKit/

2. **SenseVoice Core ML**
   - HuggingFace: https://huggingface.co/mefengl/SenseVoiceSmall-coreml
   - 官方: https://github.com/FunAudioLLM/SenseVoice

3. **Qwen3-ASR MLX Swift**
   - speech-swift: https://github.com/soniqo/speech-swift
   - MLX: https://github.com/ml-explore/mlx-swift

4. **ONNX Runtime Swift**（备选）
   - GitHub: https://github.com/microsoft/onnxruntime-swift-package-manager

### 11.2 术语表

| 术语 | 说明 |
|------|------|
| **ANE** | Apple Neural Engine，苹果神经网络引擎 |
| **RTF** | Real-Time Factor，实时率（推理时间/音频时长） |
| **MLX** | Apple 开源的机器学习框架，专为 Apple Silicon 优化 |
| **Core ML** | Apple 的机器学习模型部署框架 |
| **ITN** | Inverse Text Normalization，逆文本规范化（如将"二零二四"转为"2024"） |
| **WER** | Word Error Rate，词错误率 |

---

## 12. 变更日志

| 版本 | 日期 | 变更内容 | 作者 |
|------|------|---------|------|
| 1.0 | 2026-03-31 | 初始版本 | - |

---

**文档状态**: 待评审  
**下次评审日期**: -  
**评审人**: -
