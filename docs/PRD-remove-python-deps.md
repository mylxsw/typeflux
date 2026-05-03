# Typeflux Local Model Swift Refactoring — Product Requirements Document

## 1. Background and Goals

### 1.1 Current Problems

Typeflux's local speech-to-text functionality currently depends on a Python runtime environment, which introduces the following issues:

1. **Poor first-time user experience**: macOS 12.3+ no longer ships with Python 3 pre-installed. Users must wait several minutes on first use to install the Python runtime and dependency packages.
2. **Difficult to package and distribute**: Unable to provide a ready-to-use `.app` installation package — users must configure the environment first.
3. **High maintenance cost**: Requires maintaining a Python virtual environment, dependency version compatibility, and model download scripts.
4. **Performance overhead**: HTTP-based inter-process communication introduces additional latency.

### 1.2 Project Goals

| Goal | Description |
|------|-------------|
| **Core Objective** | Completely remove the Python dependency; implement all local model inference using Swift/native frameworks |
| **User Experience** | Achieve out-of-the-box usability — no environment configuration wait on first launch |
| **Performance Improvement** | Leverage Apple Silicon native acceleration (ANE/GPU) to reduce latency and memory usage |
| **Code Unification** | Consolidate into a single Swift codebase to reduce maintenance costs |

---

## 2. Technical Approach Overview

### 2.1 Architecture Changes

```
Current Architecture (Python Hybrid)              Target Architecture (Pure Swift)
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

### 2.2 Technology Selection Comparison

| Model | Current Approach | Target Approach | Rationale |
|-------|-----------------|-----------------|-----------|
| **Whisper** | Python + openai-whisper | **WhisperKit** (Core ML) | Best practice for Apple platforms; mature community; automatically utilizes ANE/GPU |
| **SenseVoice** | Python + FunASR | **Core ML converted model** | Community Core ML models available; fast inference speed; no external dependencies |
| **Qwen3-ASR** | Python + qwen-asr | **MLX Swift** | Pure Swift implementation; Metal GPU acceleration; native API |

---

## 3. Detailed Implementation Plan

### 3.1 Whisper Migration Plan

#### 3.1.1 Technology Selection: WhisperKit

- **Repository**: https://github.com/argmaxinc/WhisperKit
- **License**: MIT
- **Swift Version**: 5.9+
- **Platform Requirements**: macOS 13+, iOS 16+, Apple Silicon

#### 3.1.2 Integration Steps

1. **Add dependency** (Package.swift)
```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0")
]
```

2. **Model management**
   - Use WhisperKit's built-in model downloader
   - Default to the `small` model (~500 MB)
   - Model cache path: `~/Library/Caches/Typeflux/WhisperKit/`

3. **Core implementation class**
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

#### 3.1.3 Acceptance Criteria

- [ ] WhisperKit successfully integrated into the project
- [ ] Small model inference RTF < 0.1 (30%+ faster than the Python version)
- [ ] Memory usage < 1.5 GB
- [ ] Supports Chinese and English recognition

---

### 3.2 SenseVoice Migration Plan

#### 3.2.1 Technology Selection: Core ML Converted Model

- **Source**: HuggingFace `mefengl/SenseVoiceSmall-coreml`
- **Format**: `.mlmodelc` (compiled Core ML model)
- **Size**: Approximately 300–400 MB
- **Supported Languages**: Chinese, Cantonese, English, Japanese, Korean

#### 3.2.2 Integration Steps

1. **Model acquisition**
   - Download URL: https://huggingface.co/mefengl/SenseVoiceSmall-coreml
   - Automatically downloaded and cached on first run
   - Fallback: host the converted model on a self-built CDN

2. **Core ML integration**
```swift
import CoreML

final class SenseVoiceCoreMLTranscriber: Transcriber {
    private var model: MLModel?
    
    func setup() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Use ANE + GPU + CPU
        model = try await SenseVoiceSmall.load(configuration: config)
    }
    
    func transcribe(audioFile: AudioFile) async throws -> String {
        // Audio preprocessing (convert to Mel spectrogram)
        // Core ML inference
        // Post-processing (ITN, punctuation restoration)
    }
}
```

3. **Audio preprocessing**
   - Use the Accelerate framework for audio processing
   - Convert to 16 kHz mono
   - Extract 80-dimensional log-Mel features

#### 3.2.3 Alternative Approach: ONNX Runtime

If the Core ML version does not meet accuracy requirements, use ONNX Runtime:

```swift
// Using ONNX Runtime Swift
import onnxruntime

// Load model
let session = try ORTSession(modelPath: senseVoiceONNXPath)

// Run inference (automatically uses Core ML Execution Provider)
let outputs = try session.run(withInputs: ["input": melFeatures])
```

#### 3.2.4 Acceptance Criteria

- [ ] Chinese recognition accuracy >= the Python version (WER < 5%)
- [ ] Inference RTF < 0.08
- [ ] Supports emotion recognition (joy, anger, sadness, happiness labels)
- [ ] Supports audio event detection

---

### 3.3 Qwen3-ASR Migration Plan

#### 3.3.1 Technology Selection: MLX Swift

- **Recommended library**: `speech-swift` (formerly qwen3-asr-swift)
- **Repository**: https://github.com/soniqo/speech-swift
- **Tech stack**: MLX Swift (Apple's native deep learning framework)
- **Platform Requirements**: macOS 14+ (Sonoma), Apple Silicon

#### 3.3.2 Integration Steps

1. **Add dependency**
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/soniqo/speech-swift.git", from: "1.0.0")
]
```

2. **Core implementation**
```swift
import Qwen3ASR

final class Qwen3ASRMLXTranscriber: Transcriber {
    private var model: Qwen3ASR?
    
    func setup() async throws {
        // Automatically downloads the model (mlx-community/Qwen3-ASR-0.6B-bf16)
        model = try await Qwen3ASR.from_pretrained("mlx-community/Qwen3-ASR-0.6B-bf16")
    }
    
    func transcribe(audioFile: AudioFile) async throws -> String {
        let result = try await model?.transcribe(audio: audioFile.fileURL.path)
        return result?.text ?? ""
    }
}
```

3. **Model configuration**
   - Default model: Qwen3-ASR-0.6B
   - Optional model: Qwen3-ASR-1.7B (higher accuracy, slower)
   - Quantization: supports 4-bit/8-bit quantization for faster inference

#### 3.3.3 Performance Benchmarks

| Metric | Target Value | Notes |
|--------|-------------|-------|
| RTF | < 0.06 | M2 Max benchmark |
| Memory usage | ~2.2 GB | FP16 model |
| Supported languages | 52 | Including Chinese dialects |
| Initial download | ~500 MB | 0.6B model |

#### 3.3.4 Acceptance Criteria

- [ ] Chinese recognition accuracy >= the official PyTorch version
- [ ] Inference speed 20%+ faster than the Python version
- [ ] Supports long audio (> 30 seconds) with automatic chunking
- [ ] Supports timestamp alignment (optional feature)

---

## 4. Architecture Refactoring Design

### 4.1 New STT Routing Architecture

```swift
// MARK: - Unified Interface
protocol Transcriber: Sendable {
    func transcribe(audioFile: AudioFile) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String
}

// MARK: - Local Model Enum
enum LocalSTTProvider: String, CaseIterable {
    case whisperKit       // Core ML-based Whisper
    case senseVoiceCoreML // Core ML-based SenseVoice
    case qwen3ASRMLX      // MLX-based Qwen3-ASR
    
    var displayName: String {
        switch self {
        case .whisperKit:       return "Whisper (Local)"
        case .senseVoiceCoreML: return "SenseVoice (Local)"
        case .qwen3ASRMLX:      return "Qwen3-ASR (Local)"
        }
    }
}

// MARK: - Factory Pattern for Creating Transcribers
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

### 4.2 Model Manager Design

```swift
final class LocalModelManager: ObservableObject {
    // Model download status
    @Published var downloadProgress: [LocalSTTProvider: Double] = [:]
    @Published var modelStates: [LocalSTTProvider: ModelState] = [:]
    
    // Check whether a model has been downloaded
    func isModelReady(_ provider: LocalSTTProvider) -> Bool
    
    // Download / update model
    func downloadModel(_ provider: LocalSTTProvider) async throws
    
    // Delete model to free up space
    func deleteModel(_ provider: LocalSTTProvider) throws
    
    // Get model size
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

## 5. User Interface Changes

### 5.1 Settings Page Adjustments

**Local model settings page redesign:**

```
┌─────────────────────────────────────────────────────┐
│  Local Model Settings                               │
├─────────────────────────────────────────────────────┤
│  Select Model Provider                              │
│  ○ Whisper (Local)          [Downloaded] [Delete]   │
│    └─ Model size: 500 MB                            │
│    └─ Supported languages: 100+                     │
│                                                      │
│  ○ SenseVoice (Local)       [Not Downloaded] [Download] │
│    └─ Model size: 350 MB                            │
│    └─ Supported languages: ZH/EN/JA/KO             │
│    └─ Features: emotion recognition, audio event detection │
│                                                      │
│  ○ Qwen3-ASR (Local)        [Update]               │
│    └─ Model size: 500 MB (0.6B) / 1.2 GB (1.7B)   │
│    └─ Supported languages: 52                       │
│    └─ Features: Chinese dialect support             │
├─────────────────────────────────────────────────────┤
│  [Advanced Settings]                                │
│  • Model precision: Default / FP16 / INT8 / INT4   │
│  • Compute device: Auto / ANE / GPU / CPU          │
└─────────────────────────────────────────────────────┘
```

### 5.2 First-Run Onboarding

**New user flow:**

1. The user selects a local model as the STT provider.
2. If the model has not been downloaded, an onboarding dialog appears:
   - Displays the model size and estimated download time.
   - Offers "Download Now" and "Download Later" options.
3. After the download completes, the model is automatically enabled.
4. No app restart is required.

---

## 6. Data Migration Plan

### 6.1 User Settings Migration

| Old Setting | New Setting | Migration Strategy |
|------------|------------|-------------------|
| `stt.local.model` = `whisperLocal` | `stt.local.provider` = `whisperKit` | Automatic migration, preserves Whisper selection |
| `stt.local.model` = `senseVoiceSmall` | `stt.local.provider` = `senseVoiceCoreML` | Automatic migration |
| `stt.local.model` = `qwen3ASR` | `stt.local.provider` = `qwen3ASRMLX` | Automatic migration |
| `stt.local.modelIdentifier` | Removed | Uses each model's default configuration |

### 6.2 Legacy Data Cleanup

- Detect the old Python virtual environment at: `~/Library/Application Support/Typeflux/STT/Runtime/`
- Prompt the user whether to clean it up (can free 2–5 GB of disk space)
- Provide a one-click cleanup function

---

## 7. Risk Assessment and Mitigation

| Risk | Impact | Likelihood | Mitigation Strategy |
|------|--------|------------|---------------------|
| **SenseVoice Core ML accuracy falls short** | High | Medium | Use ONNX Runtime as a fallback |
| **speech-swift library maintenance is unstable** | High | Low | Prepare mlx-qwen3-asr as a fallback (pure Python MLX) |
| **WhisperKit model download is slow** | Medium | Medium | Set up a domestic CDN mirror or pre-bundle the model |
| **MLX only supports macOS 14+** | Medium | High | Provide WhisperKit as a downgrade path for macOS 13 users |
| **Core ML model file size is too large** | Low | Medium | Offer INT8 quantized versions, reducing size by ~50% |
| **Development timeline exceeds estimates** | Medium | Medium | Prioritize Phases 1–2 to ensure WhisperKit is usable; SenseVoice/Qwen3 can be iterated on later |

---

## 8. Performance Benchmarks

### 8.1 Target Performance Metrics

| Model | Inference RTF | Memory Usage | First Cold Start | Model Size |
|-------|--------------|--------------|------------------|------------|
| Whisper (small) | < 0.08 | < 1.2 GB | < 2 s | ~500 MB |
| SenseVoice (small) | < 0.06 | < 1.0 GB | < 1.5 s | ~350 MB |
| Qwen3-ASR (0.6B) | < 0.06 | < 2.5 GB | < 2 s | ~500 MB |

### 8.2 Comparison with Current Python Approach

| Metric | Python Approach | Swift Target | Improvement |
|--------|----------------|-------------|-------------|
| First launch time | 3–5 minutes | < 10 seconds | **30–50x** |
| Memory usage | 2–5 GB | 1–2.5 GB | **50%** |
| Inference latency | Baseline | 20–40% faster | **20–40%** |
| Package size | Requires Python runtime | Single `.app` | **Vastly simplified** |

---

## 9. Acceptance Criteria

### 9.1 Functional Acceptance

- [ ] All three local models (WhisperKit, SenseVoice, Qwen3-ASR) can correctly transcribe speech
- [ ] Model download, update, and deletion functions work properly
- [ ] The settings page allows switching between different local models
- [ ] Legacy user settings are migrated automatically
- [ ] The old Python environment can be cleaned up with one click

### 9.2 Performance Acceptance

- [ ] All local models achieve RTF < 0.1
- [ ] Memory usage is reduced by 30%+ compared to the Python version
- [ ] First launch does not require waiting for a Python environment to be installed

### 9.3 User Experience Acceptance

- [ ] New users can use local models immediately after downloading the app (only the model files need to be downloaded)
- [ ] Model download progress is displayed
- [ ] Error messages are clear (network issues, insufficient disk space, etc.)

---

## 10. Appendix

### 10.1 Reference Resources

1. **WhisperKit**
   - GitHub: https://github.com/argmaxinc/WhisperKit
   - Documentation: https://argmaxinc.github.io/WhisperKit/

2. **SenseVoice Core ML**
   - HuggingFace: https://huggingface.co/mefengl/SenseVoiceSmall-coreml
   - Official: https://github.com/FunAudioLLM/SenseVoice

3. **Qwen3-ASR MLX Swift**
   - speech-swift: https://github.com/soniqo/speech-swift
   - MLX: https://github.com/ml-explore/mlx-swift

4. **ONNX Runtime Swift** (alternative)
   - GitHub: https://github.com/microsoft/onnxruntime-swift-package-manager

### 10.2 Glossary

| Term | Definition |
|------|-----------|
| **ANE** | Apple Neural Engine |
| **RTF** | Real-Time Factor — the ratio of inference time to audio duration |
| **MLX** | Apple's open-source machine learning framework, optimized for Apple Silicon |
| **Core ML** | Apple's machine learning model deployment framework |
| **ITN** | Inverse Text Normalization — e.g., converting spoken "twenty twenty-four" to "2024" |
| **WER** | Word Error Rate |

---

## 11. Change Log

| Version | Date | Changes | Author |
|---------|------|---------|--------|
| 1.0 | 2026-03-31 | Initial version | - |
