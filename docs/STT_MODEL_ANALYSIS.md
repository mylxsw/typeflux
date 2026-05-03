# Typeflux Speech Model Architecture Analysis Report

## Local Speech Models (LocalSTTModel)

The project currently supports **5 local ASR (Automatic Speech Recognition) models**:

### 1. SenseVoice-Small (Recommended)

- **Category**: Multilingual general-purpose model
- **Parameters**: ~400M
- **Features**: Supports Chinese, English, Japanese, Korean, Cantonese, and more
- **Execution Framework**: ONNX + Sherpa-ONNX
- **Model Structure**: INT8 quantization
- **Operation**:
  - Uses the `sherpa-onnx-offline` binary
  - Invokes `model.int8.onnx` for inference
  - Uses `tokens.txt` for vocabulary decoding
  - Automatic language detection (`--sense-voice-language=auto`)
  - Supports ITN (Inverse Text Normalization)

### 2. Qwen3-ASR

- **Category**: Chinese-optimized model (Alibaba Qwen series)
- **Parameters**: 0.6B (smaller)
- **Features**: Focused on Chinese recognition with high accuracy
- **Execution Framework**: ONNX + Sherpa-ONNX
- **Model Structure**: INT8 quantization with modular design
- **Operation**:
  - Three-layer modular architecture:
    - `conv_frontend.onnx`: Audio frontend processing
    - `encoder.int8.onnx`: Feature encoding
    - `decoder.int8.onnx`: Text decoding
  - `tokenizer` directory: Tokenizer files
  - Fixed parameters: max total length=1500, max new tokens=512, temperature=0 (deterministic output)

### 3. FunASR (Paraformer)

- **Category**: Open-source general-purpose ASR model (Alibaba)
- **Features**: Lightweight, low latency
- **Execution Framework**: ONNX + Sherpa-ONNX
- **Model Structure**: INT8 quantization
- **Operation**:
  - `model.int8.onnx`: Single inference model
  - `tokens.txt`: Vocabulary

### 4. Whisper-Local (Medium)

- **Category**: OpenAI Whisper local version
- **Features**: Multilingual (99 languages), open-source, rich community resources
- **Execution Framework**: WhisperKit (CoreML)
- **Operation**: Runs CoreML format model directly on device

### 5. Whisper-Local-Large

- Similar to the Medium version but with more parameters, higher accuracy, and slower speed

---

## Current Parameter Configuration

Model parameters are primarily configured in `SherpaOnnxSupport.swift`:

### SenseVoice Parameters (L815-823)

```
--print-args=false            # Suppress argument logging (saves log space)
--tokens=<path>               # Vocabulary file path
--sense-voice-model=<path>    # INT8 quantized model path
--sense-voice-language=auto   # Automatic language detection (supports mixed Chinese-English)
--sense-voice-use-itn=true    # Enable inverse text normalization (1000 -> 千)
--provider=cpu                # Force CPU (not GPU)
<audio-file>                  # Input audio file path
```

### Qwen3-ASR Parameters (L824-837)

```
--qwen3-asr-conv-frontend=<path>  # Audio processing layer
--qwen3-asr-encoder=<path>        # Encoding layer (INT8)
--qwen3-asr-decoder=<path>        # Decoding layer (INT8)
--qwen3-asr-tokenizer=<path>      # Tokenizer path
--qwen3-asr-max-total-len=1500    # Maximum input sequence length
--qwen3-asr-max-new-tokens=512    # Maximum output tokens
--qwen3-asr-temperature=0         # Temperature (0=deterministic, >0=randomness)
--provider=cpu                    # CPU inference
<audio-file>
```

### FunASR Parameters (L838-845)

```
--tokens=<path>                   # Vocabulary
--paraformer=<path>               # Paraformer model
--provider=cpu
<audio-file>
```

---

## Remote Speech Models (STTProvider)

The project supports **9 remote STT providers**:

| Provider | Model Type | Features | Configuration |
|----------|-----------|----------|---------------|
| **typefluxOfficial** | Proprietary | Typeflux own service | Default priority |
| **freeModel** | Free model | Community open-source | - |
| **localModel** | Local | 5 local models | See above |
| **aliCloud** | Alibaba Cloud | `fun-asr-realtime` | Cloud service, requires API key |
| **doubaoRealtime** | ByteDance | Doubao real-time recognition | Cloud service, requires Resource ID |
| **googleCloud** | Google Cloud | `chirp_3`, `long`, `short` | Requires GCP credentials |
| **whisperAPI** | OpenAI | Whisper API | Requires OpenAI API Key |
| **multimodalLLM** | LLM Audio | Audio processing via LLM | Requires LLM endpoint configuration |
| **groq** | Groq API | Fast inference API | Requires Groq API Key |

---

## Best Practice Recommendations

### Model Selection

1. **Pure Chinese scenarios**: Qwen3-ASR (fastest, smallest)
2. **Mixed Chinese-English**: SenseVoice-Small (most balanced)
3. **99 languages**: Whisper-Local (most flexible, slowest)
4. **Production environments**: Default to typefluxOfficial, fallback to localModel
5. **Real-time low latency**: FunASR (lightweight)

### Parameter Optimization

#### SenseVoice Optimization

```swift
// Key configurable parameters:
// 1. Language detection: switch to specific language when scenario is known
// --sense-voice-language=zh (Chinese)
// --sense-voice-language=en (English)

// 2. ITN processing: if "1000" is preferred over "一千"
// --sense-voice-use-itn=false  # Disabling may improve speed by ~5-10%
```

#### Qwen3-ASR Optimization

```swift
// Current parameter analysis:
// max-total-len=1500    # Supports approximately 5 minutes of audio (16kHz sample rate)
// max-new-tokens=512    # Limits output length, prevents repetition
// temperature=0         # Deterministic output, recommended to keep

// Tunable parameters:
// --qwen3-asr-max-total-len      # Balance memory vs. length
// --qwen3-asr-max-new-tokens     # Increase to 1024 for long audio
// temperature                    # For diversity: 0.1-0.3
```

---

## Optional Optimization Parameters

### Sherpa-ONNX Parameters Available but Not Currently Configured

Consider adding the following parameters for further optimization:

```swift
// 1. Compute provider selection (currently hardcoded to cpu)
--provider=cpu              # Current configuration
--provider=cpu+mkldnn       # CPU + Intel optimized library (not supported on Mac)
--provider=coreml           # CoreML (Whisper only)

// 2. Thread control (Qwen3-ASR)
--qwen3-asr-num-threads=4   # CPU thread count, default is auto
                             # For Mac M-series, recommended to leave unset

// 3. Feature extraction parameters (SenseVoice)
--sense-voice-normalize-samples=true  # Audio normalization
--sense-voice-verbose=false           # Log output

// 4. Cache optimization
--print-args=true           # Print arguments for debugging, set to false in production
```

### Model Download Source Optimization

The current code supports two sources:

- **HuggingFace** (Recommended by default, more stable)
- **ModelScope** (China mirror, fallback)

```swift
// Configurable in LocalSTTConfiguration
downloadSource = .huggingFace    # International network
downloadSource = .modelScope     # China network optimization
```

### Memory Optimization Options

```swift
// LocalModelTranscriber.swift
localSTTMemoryOptimizationEnabled  # Currently supported option
// When enabled: WhisperKit cache released after 30 minutes (saves memory)
// When disabled: WhisperKit persistent cache (faster response)

// Recommendations:
// - Mobile applications: enabled (memory constrained)
// - Servers: disabled (cache reuse)
```

---

## Diagnostics and Monitoring Recommendations

```swift
// Current log output location: NetworkDebugLogger
// Each transcription records:
{
  "provider": "senseVoiceSmall",
  "model": "sensevoice-small",
  "mode": "native",
  "prompt": "<vocabulary-hint>",  // Keyword hints
  "file": {"path": "..."}
}

// Recommended monitoring metrics:
1. Transcription latency (sttMilliseconds)     Available
2. Model loading time                            Missing
3. Peak GPU/Memory usage                         Missing
4. Feature extraction time                       Missing
5. Decoding time                                 Missing
```

---

## Current Benchmark Metrics Interpretation

The `local_asr_benchmark.py` tracks the following key metrics:

```
wholeTranscriptDistance      # Edit distance (lower is better, 0=perfect match)
expectedTermRecall           # Target vocabulary recognition rate (range 0-1)
protectedTermExactMatch      # Protected term exact match (mandatory accuracy)
stt_realtime_factor          # Real-time factor (<1 = faster than real-time)
```

---

## Summary

| Dimension | Current Status | Optimization Direction |
|-----------|---------------|----------------------|
| **Model Support** | 5 local + 9 cloud | Complete |
| **Parameter Configuration** | Core parameters configured | Fine-tune temperature, thread count |
| **Performance Monitoring** | Basic monitoring in place | Add granular timing analysis |
| **Memory Management** | WhisperKit cache management | Optimized |
| **Download Sources** | Dual-source support | Complete |
| **Chinese-English Mixed** | SenseVoice + Qwen3 | Full support |

The project architecture is well-designed and serves as an excellent unified speech interface supporting multiple models and providers.
