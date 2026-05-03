# Typeflux Local Model Architecture

> This document is written for readers who are new to concepts like local models, speech recognition, and inference engines. If you are already familiar with these topics, feel free to skip ahead to [Architecture Overview](#3-architecture-overview).

---

## 1. Why Do We Need "Local Models"?

The core Typeflux experience is simple: **hold a hotkey, speak, release, and the transcribed text is automatically inserted into the app you are using**.

The most critical step in this workflow is **Speech-to-Text (STT)** -- converting the audio signal from your voice into editable text on screen. There are two ways to accomplish this:

| | Cloud Transcription | Local Transcription |
|---|---|---|
| How it works | Audio is sent to a remote server, which runs the model and returns the result | The model runs directly on your own Mac, completing transcription on-device |
| Advantages | Larger models, higher accuracy, no local compute needed | Works offline, free, fast, and private |
| Disadvantages | Requires network, may cost money, audio data leaves your device | Requires local compute; model files must be downloaded or bundled |

Typeflux supports both approaches. This document focuses exclusively on how **local transcription** works.

In one sentence: **a local model means the entire "understanding what you said" process happens on your own computer, without involving any server.**

---

## 2. Two Easily Confused Concepts: Runtime vs. Model

The two terms that beginners most often mix up are "runtime" and "model." Here is an analogy:

> **Runtime = a media player (like VLC)**
> **Model = a movie file (like an .mkv)**

- The **player** knows how to decode video, render frames, and output audio. But it does not contain any movie content itself -- give it a different movie file, and it plays a different movie.

- The **movie file** contains the actual visual content. But it cannot "play" by itself -- you need a player to open it.

In the world of speech recognition:

- A **Runtime** is an inference engine. It knows how to feed audio data into a model, execute the computation, and retrieve the results. It contains no "speech knowledge" on its own.
- A **Model** is a collection of trained neural network weights (essentially huge numerical matrices). It encodes all the learned knowledge about "what sound maps to what text."

The two are downloaded and stored independently. Typeflux combines them when needed.

---

## 3. Architecture Overview

Typeflux supports five local models, backed by two entirely different runtimes:

```
                         STTRouter (Routing Layer)
                              │
                              ▼
                     LocalModelTranscriber (Local Transcription Controller)
                       │                │
                       ▼                ▼
              ┌─ WhisperKit Runtime ─┐   ┌─ Sherpa-ONNX Runtime ─┐
              │  (Apple CoreML)      │   │  (ONNX Runtime)        │
              │                      │   │                        │
              │  ● whisperLocal      │   │  ● senseVoiceSmall     │
              │  ● whisperLocalLarge │   │  ● qwen3ASR            │
              └──────────────────────┘   │  ● funASR              │
                                         └────────────────────────┘
```

The following sections cover each runtime in detail.

---

## 4. Runtime A: WhisperKit (Apple-Native Approach)

### What It Is

WhisperKit is an open-source Swift library developed by [Argmax](https://github.com/argmaxinc/WhisperKit). It converts OpenAI's open-source **Whisper** speech recognition model into Apple's CoreML format, enabling it to run at high speed on the **Neural Engine** built into Apple Silicon chips.

### What the Model Files Look Like

WhisperKit models are organized as a set of compiled CoreML directories:

```
whisperkit-medium/
├── MelSpectrogram.mlmodelc/    ← Audio spectrogram analysis component
│   ├── model.mlmodel
│   └── weights/weight.bin
├── AudioEncoder.mlmodelc/      ← Audio feature encoding component
│   ├── model.mlmodel
│   └── weights/weight.bin
└── TextDecoder.mlmodelc/       ← Text decoding component
    ├── model.mlmodel
    └── weights/weight.bin
```

These three components form a pipeline:

1. **MelSpectrogram**: Converts raw audio waveforms into a "spectrogram" -- time on the horizontal axis, frequency on the vertical axis, and color intensity representing energy. This is the standard input format for speech recognition.
2. **AudioEncoder**: Reads the spectrogram and extracts meaningful speech feature vectors. Think of it as "figuring out which phonemes and intonations are present in the audio."
3. **TextDecoder**: Takes the feature vectors and generates the final text output, one token at a time.

### How It Works

WhisperKit runs **in-process** -- its code is compiled directly into Typeflux's main process:

```
Typeflux Process
  ├── Your App Logic
  └── WhisperKit Library
       └── CoreML Inference (executed on Neural Engine / GPU / CPU)
```

- **Advantages**: Supports streaming progress callbacks (partial results are displayed as they arrive) and has low latency.
- **Trade-offs**: The medium model is roughly 1.5 GB; the large-v3 model is about 3 GB. Once loaded into memory, they consume significant resources.
- **Best for**: Situations where transcription quality is a priority and the Mac has sufficient memory.

### Key Types in the Code

| Type | Responsibility |
|------|----------------|
| `WhisperKitTranscriber` | Wraps the WhisperKit library; handles pipeline creation and transcription execution |
| `LocalModelTranscriber` | The main controller for local transcription; maintains a `whisperKitCache` for loaded WhisperKit instances |

Caching strategy: WhisperKit instances are cached with a key of `"model name|model path"`. When memory optimization is enabled, instances unused for 30 minutes are automatically released; otherwise they remain in memory.

---

## 5. Runtime B: Sherpa-ONNX (Cross-Platform Approach)

### What It Is

Sherpa-ONNX is a speech processing toolkit developed by the [k2-fsa](https://github.com/k2-fsa/sherpa-onnx) project. It uses Microsoft's **ONNX Runtime** as its inference engine. It provides a command-line program called `sherpa-onnx-offline` that accepts an audio file as input and outputs the transcription.

### What "Quantization" Means

You will notice that some model filenames contain the `int8` suffix (e.g., `model.int8.onnx`). This refers to **quantization**:

- Neural network weights are originally stored as 32-bit floating-point numbers (float32), with each value taking 4 bytes.
- **int8 quantization** compresses them into 8-bit integers, taking only 1 byte each.
- The result: **the model is roughly 4 times smaller, with accuracy loss typically within 1--2%**.

This is one of the main reasons why the SenseVoice model is only 47 MB while Whisper medium requires 1.5 GB.

### What the Model Files Look Like

Different models have slightly different file structures:

**SenseVoice Small (47 MB, the default model):**
```
sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
├── model.int8.onnx      ← Quantized neural network weights
└── tokens.txt            ← Vocabulary (characters and words the model can recognize)
```

**Qwen3-ASR 0.6B (Qwen speech model):**
```
sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/
├── conv_frontend.onnx    ← Audio frontend convolutional network
├── encoder.int8.onnx     ← Encoder
├── decoder.int8.onnx     ← Decoder
└── tokenizer/
    ├── merges.txt        ← BPE tokenization merge rules
    ├── tokenizer_config.json
    └── vocab.json         ← Vocabulary
```

**FunASR / Paraformer:**
```
sherpa-onnx-paraformer-zh-small-2024-03-09/
├── model.int8.onnx
└── tokens.txt
```

### How It Works

Sherpa-ONNX runs **out-of-process** -- Typeflux spawns a separate child process to perform transcription:

```
Typeflux Process                    Child Process
  │                                   │
  │  1. Convert audio to WAV format   │
  │  2. Spawn Process                 │
  │ ────────────────────────────────▶│  sherpa-onnx-offline
  │                                   │    --sense-voice-model=model.int8.onnx
  │                                   │    --tokens=tokens.txt
  │                                   │    audio.wav
  │  3. Read stdout output            │
  │ ◀────────────────────────────────│  → Outputs transcription text
  │  4. Child process exits, memory released
```

- **Advantages**: Memory is freed as soon as the model finishes; no resources are consumed in the main process; a crash in the child process does not affect the main app.
- **Trade-offs**: No intermediate progress feedback -- you must wait for the entire process to finish.
- **Best for**: Everyday quick voice input (hold-to-talk, release-to-insert), where response speed matters more than absolute accuracy.

### Key Types in the Code

| Type | Responsibility |
|------|----------------|
| `SherpaOnnxCommandLineDecoder` | Low-level generic decoder: prepares arguments, spawns the child process, parses stdout output |
| `SenseVoiceTranscriber` | SenseVoice-specific wrapper; sets the `--sense-voice-*` arguments |
| `Qwen3ASRTranscriber` | Qwen3-ASR-specific wrapper; sets the `--qwen3-asr-*` arguments |
| `FunASRTranscriber` | FunASR/Paraformer-specific wrapper; sets the `--paraformer` argument |
| `AudioFileTranscoder` | Audio format conversion: normalizes various formats to 16-bit PCM WAV |

---

## 6. What Are "CoreML" and "ONNX"?

These two terms refer to two different **model file format standards**:

| Format | Maintained By | Characteristics |
|--------|---------------|-----------------|
| **CoreML** | Apple | Apple-platform exclusive; can leverage Neural Engine hardware acceleration; only runs on macOS/iOS |
| **ONNX** | Microsoft (open-source community maintained) | Cross-platform standard; works on Windows/Linux/macOS; may not use specialized hardware |

An analogy: CoreML is like `.mov` (optimized for the Apple ecosystem), while ONNX is like `.mp4` (plays everywhere). After a model is trained, it must be converted into the appropriate format for the target runtime.

---

## 7. Runtime Binaries: Sherpa-ONNX's "Engine Package"

Since Sherpa-ONNX runs out-of-process, it requires a set of executable files to function. The runtime package used by Typeflux is `sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts`, which contains:

```
sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/
├── bin/
│   └── sherpa-onnx-offline      ← Main program (accepts audio, outputs text)
└── lib/
    ├── libsherpa-onnx-c-api.dylib      ← Sherpa-ONNX core library
    ├── libonnxruntime.dylib             ← ONNX Runtime inference engine
    └── libonnxruntime.1.23.2.dylib      ← ONNX Runtime versioned library
```

- `sherpa-onnx-offline` is the command-line tool that actually performs inference.
- The dynamic libraries (`.dylib`) provide the low-level computation support needed for inference.
- `osx-universal2` means it supports both Intel and Apple Silicon Macs.
- `no-tts` means text-to-speech functionality is not included (Typeflux only needs speech-to-text).
- Release packaging audits these Mach-O binaries so their declared macOS `minos` does not silently exceed the supported runtime floor.

These files can be **downloaded from the internet** or **bundled inside the .app package** (see Section 9).

---

## 8. File Storage Layout

All local model-related files are stored under `~/Library/Application Support/Typeflux/LocalModels/`:

```
~/Library/Application Support/Typeflux/LocalModels/
├── senseVoiceSmall/
│   └── sensevoice-small/
│       ├── sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/  ← Runtime
│       │   ├── bin/sherpa-onnx-offline
│       │   └── lib/*.dylib
│       ├── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/  ← Model
│       │   ├── model.int8.onnx
│       │   └── tokens.txt
│       └── prepared.json                                         ← Ready marker
│
├── qwen3ASR/
│   └── <identifier>/
│       ├── sherpa-onnx-v1.12.35-.../                            ← Runtime (may be shared)
│       ├── sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/          ← Model
│       └── prepared.json
│
├── whisperLocal/
│   └── <identifier>/
│       ├── MelSpectrogram.mlmodelc/
│       ├── AudioEncoder.mlmodelc/
│       ├── TextDecoder.mlmodelc/
│       └── prepared.json
│
└── ... (other models follow the same pattern)
```

Each model directory contains a `prepared.json` file that records the model's metadata:

```json
{
    "model": "senseVoiceSmall",
    "modelIdentifier": "sensevoice-small",
    "storagePath": "/Users/you/Library/Application Support/Typeflux/LocalModels/senseVoiceSmall/sensevoice-small",
    "source": "huggingFace",
    "preparedAt": "2026-05-02T10:30:00Z"
}
```

Before using a model, the app checks for this file -- if it exists and the path is valid, the model is considered ready; otherwise, a download is triggered.

---

## 9. Bundled Model Mechanism

The app can be built in two variants:

| Variant | What Is Bundled | First-Use Experience | App Size |
|---------|-----------------|---------------------|----------|
| **Minimal** | Only Sherpa-ONNX runtime binaries | Model files must be downloaded on first use (about 47 MB) | Smaller |
| **Full** | Runtime + SenseVoice model files included | Works out of the box, no download needed | Larger |

Bundled files are placed inside the `.app` package:

```
Typeflux.app/Contents/Resources/
├── BundledModels/
│   └── senseVoiceSmall/
│       └── sensevoice-small/
│           ├── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/  ← Bundled model
│           └── sherpa-onnx-v1.12.35-.../ → Symlink to LocalRuntimes
└── LocalRuntimes/
    └── sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/           ← Bundled runtime
        ├── bin/sherpa-onnx-offline
        └── lib/*.dylib
```

At app launch, `BundledLocalModelLocator` searches three candidate paths for bundled models. Once found, `LocalModelManager` creates a **symbolic link (symlink)** that points the bundled model into the `LocalModels/` directory. This way, all downstream code uses the same path regardless of whether the model was bundled or downloaded.

---

## 10. Model Download Mechanism

When a user-selected model is not available locally, Typeflux automatically downloads it.

### Download Source Selection

Each model has two download sources:

| Source | URL | Best For |
|--------|-----|----------|
| **HuggingFace** | `huggingface.co` | International users (default) |
| **China Mirror** | `hf-mirror.com` / ModelScope | Users in China (faster speeds) |

`NetworkLocalModelDownloadSourceResolver` **simultaneously probes all sources for latency** (using HEAD requests), then ranks them by response speed and prioritizes the fastest one.

### Auto-Download (AutoModelDownloadService)

In addition to user-triggered downloads, Typeflux has a background auto-download mechanism:

- **When it triggers**: At app launch, and when the user enables the "local optimization" setting.
- **Default target**: SenseVoice Small (regardless of CPU architecture, since it is the lightest).
- **Retry strategy**: Exponential backoff -- immediate retry, then after 1 minute, 3 minutes, 9 minutes, and so on, up to a maximum interval of 3 hours.
- **State persistence**: Download state is saved in `UserDefaults`, so restarting the app does not start the download from scratch.

The purpose of auto-downloading is: **even if the user has selected a cloud transcription service, the local model is quietly prepared in the background, ready to serve as a fallback at any time.**

---

## 11. End-to-End Transcription Flow

Tying all the components together, here is the complete flow for a single local transcription:

### WhisperKit Path (In-Process)

```
[User Action] Hold down the hotkey
    │
    ▼
[Recording] AudioRecorder captures microphone audio via AVFoundation
    │
    ▼
[Warm-up] prepareForRecording() → Pre-loads the WhisperKit pipeline into memory
    │      (Don't waste the time while the user is still speaking)
    ▼
[User Action] Release the hotkey
    │
    ▼
[Routing] LocalModelTranscriber reads settings, selects whisperLocal / whisperLocalLarge
    │
    ▼
[Model Lookup] preparedModelInfo() → Check bundled first, then prepared.json, trigger download if neither exists
    │
    ▼
[Transcription] WhisperKitTranscriber.transcribe(audio path)
    │   ├── Internally calls the WhisperKit library's pipeline.transcribe()
    │   ├── CoreML executes inference on the Neural Engine
    │   └── Progress callbacks → Partial transcription results can be displayed in real time
    │
    ▼
[Output] Receive the complete transcription text
    │
    ▼
[Next Steps] Optional LLM polishing → TextInjector inserts text into the foreground app
```

### Sherpa-ONNX Path (Out-of-Process)

```
[User Action] Hold down the hotkey
    │
    ▼
[Recording] AudioRecorder captures microphone audio
    │
    ▼
[User Action] Release the hotkey
    │
    ▼
[Routing] LocalModelTranscriber reads settings, selects senseVoiceSmall / qwen3ASR / funASR
    │
    ▼
[Model Lookup] preparedModelInfo() → Checks whether the model and runtime are ready
    │
    ▼
[Transcoding] AudioFileTranscoder converts audio to 16-bit PCM WAV format
    │
    ▼
[Transcription] SherpaOnnxCommandLineDecoder
    │   ├── Constructs command-line arguments (model path, language, token limit, etc.)
    │   ├── Spawns child process: sherpa-onnx-offline <args> <audio file>
    │   ├── Sets DYLD_LIBRARY_PATH to point to the runtime's lib/ directory
    │   └── Reads the child process's stdout output (plain text or JSON)
    │
    ▼
[Output] Receive the transcription text
    │
    ▼
[Next Steps] Optional LLM polishing → TextInjector inserts text into the foreground app
```

---

## 12. Multi-Level Fallback Strategy

Typeflux does not give up entirely just because one transcription method fails. `STTRouter` implements a multi-level fallback chain:

```
Primary transcription method (user-selected cloud/local method)
    │ Failure
    ▼
Auto local model (SenseVoice downloaded by AutoModelDownloadService)
    │ Failure
    ▼
Apple Speech framework (macOS built-in speech recognition)
    │ Failure
    ▼
Error
```

The specific rules are:

- **If the user selected the Typeflux Official cloud service**: Try the local auto-model first (to save cloud credits). If that fails, fall back to the cloud service. If the cloud also fails, fall back to Apple Speech.
- **If the user selected another cloud service**: Cloud failure triggers a try of the local auto-model first, then Apple Speech.
- **If the user selected a local method**: Local failure triggers a direct fallback to Apple Speech.

This means: **even if you are on an airplane with no network, Typeflux can still work.**

---

## 13. How to Choose Among the Five Models

| Model | Size | Chinese Quality | English Quality | Speed | Best For |
|-------|------|-----------------|-----------------|-------|----------|
| **SenseVoice Small** (default) | 47 MB | ★★★★ | ★★★ | Fast | Everyday Chinese voice input; best value for size |
| **Qwen3-ASR** | ~300 MB | ★★★★ | ★★★★ | Medium | Frequent Chinese-English mixed scenarios |
| **FunASR / Paraformer** | ~80 MB | ★★★ | ★★ | Fast | Chinese-only scenarios with limited resources |
| **WhisperKit Medium** | ~1.5 GB | ★★★★ | ★★★★★ | Slower | High English quality requirements with ample memory |
| **WhisperKit Large-v3** | ~3 GB | ★★★★ | ★★★★★ | Slow | Maximum accuracy, unconcerned about resource usage |

**Recommendation**: If you are unsure which to choose, **stick with the default SenseVoice Small**. It is small, fast, and handles Chinese well -- the optimal choice for Typeflux's hold-to-talk, release-to-insert quick-interaction workflow.

---

## 14. Key Design Decisions Revisited

1. **Two runtimes coexist**: WhisperKit (in-process, streaming, high quality but heavy) and Sherpa-ONNX (out-of-process, batch, lightweight but no progress feedback). Different scenarios use different approaches rather than a one-size-fits-all solution.

2. **Runtime and model decoupling**: Runtimes and models are downloaded, stored, and versioned independently. This means upgrading a model does not require reinstalling the runtime, and vice versa.

3. **Dual download sources + latency probing**: HuggingFace and China mirrors coexist, with real-time speed detection to select the optimal source, ensuring a good experience for users worldwide.

4. **Aggressive fallback chain**: Primary method -> local auto-model -> Apple Speech. Failure at any layer does not bring the app to a halt.

5. **Lazy + Eager loading strategy**: WhisperKit begins warming up while the user is still speaking (eager), while Sherpa models require no warm-up since they run out-of-process. This strikes a balance between resource consumption and response speed.

6. **Bundled + on-demand download**: The Full variant works out of the box; the Minimal variant downloads automatically on first use. Symlinks unify the paths so that downstream code does not need to distinguish between bundled and downloaded models.

---

## 15. Related Documents

- [LOCAL_ASR_BENCHMARK.md](./LOCAL_ASR_BENCHMARK.md) — Local ASR model benchmarks
- [BUILD_CONFIGURATION.md](./BUILD_CONFIGURATION.md) — Build and signing configuration (including bundled model build variants)
- [MAKE_COMMANDS.md](./MAKE_COMMANDS.md) — Makefile command reference
