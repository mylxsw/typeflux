# macOS Voice Input Tool (Swift) — Product Requirements Document (Updated Draft)

## 1. Background

Build a "hold to talk, release to input" voice input tool for macOS that lives in the menu bar. A configurable hotkey triggers audio recording; the resulting speech-to-text output is inserted directly at the current cursor position and simultaneously copied to the clipboard. The tool also supports a configurable LLM service integration (OpenAI-compatible protocol), history management and export, and an enhanced mode where selected text can be edited and replaced via voice commands.

## 2. Goals

- **Minimal interaction**: hold to trigger → record → release to end → stream transcription/generation → auto-insert and copy.
- **Two modes**:
  - **Standard input mode**: transcribe speech to text and insert at the cursor position.
  - **Text editing mode**: triggered after selecting text; combines the selection with a voice command to generate new text and replace the original selection.
- **Settings UI** allows configuring the hotkey and LLM connection details; hotkey changes take effect immediately.
- **History** retains the most recent week of entries, with playback, export, and clear capabilities.

## 3. Scope

### 3.1 In Scope

- Menu bar resident app with status management
- Hotkey triggering (default Fn; supports configurable key combinations)
- Recording overlay (fixed position, waveform display, and timer)
- OpenAI-compatible protocol (ChatGPT / OpenAI-compatible) integration with streaming and failure retry
- Text injection (insert at cursor / replace selection) and clipboard synchronization
- Settings/management UI: hotkey and LLM configuration
- History: most recent week, playback, export, clear
- Project structure and coding standards

### 3.2 Out of Scope

- Encrypted storage for history (explicitly deferred)
- Account system and cross-device sync (not requested)
- Complex multilingual/punctuation strategies (not requested)

## 4. Functional Requirements

### 4.1 Core Interaction Flow

**FR-1 Menu Bar Resident**

After launch, the app resides in the system menu bar, providing access to settings, history, export/clear, and displaying the current status (ready / recording / transcribing / failed, etc.).

**FR-2 Hotkey Trigger (Default Fn + Configurable Key Combinations)**

- The default trigger key is Fn (press and hold to activate).
- The management UI allows configuring alternative hotkeys (including key combinations) to replace or supplement the Fn trigger.
- Hotkey configuration takes effect immediately (no restart or explicit "Save" click required).

**FR-3 Hold to Start Recording**

When the user presses and holds the trigger key:

- A status overlay appears below the center of the screen;
- Recording begins, displaying a real-time volume waveform and timer.

**FR-4 Release to End Recording**

Releasing the trigger key signals that input is complete:

- Recording stops immediately;
- The transcription/generation process begins (streaming).

---

### 4.2 Status Overlay (UI/State)

**FR-5 Overlay Position and Interaction**

- The overlay is non-draggable and fixed below the center of the screen.
- The overlay must include at minimum: status text, volume waveform, and timer.

**FR-6 Status Display Labels**

The overlay must display the following states (at minimum):

- **Recording** — active recording
- **Transcribing** — processing
- **Failed** — error state
- **Duplicate** — duplicate state; meaning to be defined per product requirements (see Open Questions)

**FR-7 Failure Notification and Clipboard Fallback**

When processing fails:

- The overlay must clearly indicate "Failed" to the user;
- A "Copy to clipboard" path must remain available (copy content and strategy to be defined in open questions/assumptions).

---

### 4.3 Speech Processing and API Protocol

**FR-8 OpenAI-Compatible Protocol (ChatGPT/OpenAI-compatible)**

- LLM calls use the ChatGPT OpenAI-compatible protocol.
- The management UI supports configuring: endpoint (Base URL/Endpoint), API Key, model identifier, and other required parameters.

**FR-9 Streaming**

The processing phase uses streaming to retrieve results (text is returned incrementally).

**FR-10 Retry Mechanism**

Failed API calls are automatically retried up to 3 times (cumulative count including the initial attempt).

---

### 4.4 Text Distribution (Insertion and Clipboard)

**FR-11 Auto-Insertion**

Transcribed/generated text must be reliably inserted at the cursor position or input point of the currently focused application.

**FR-12 Clipboard Synchronization**

Transcribed/generated text must be simultaneously copied to the system clipboard.

**FR-13 Universal App Compatibility**

- Text injection must be compatible with all applications (treated as a strong constraint).
- If injection is not possible in certain scenarios, clipboard synchronization must at minimum remain available, with UI feedback provided (degradation strategy to be formalized in the technical design).

---

### 4.5 Text Editing Mode

**FR-14 Entering Edit Mode**

When the user selects a block of text and then presses and holds the trigger key, the app enters edit mode.

**FR-15 Editing Logic**

The selected text serves as the target for modification. Combined with the user's voice command, it is processed to produce the modified content.

**FR-16 Auto-Replacement and Clipboard Synchronization**

The modified content automatically replaces the original selection and is simultaneously copied to the clipboard.

**FR-17 Edit Mode UI Constraints**

No special visual indicator is needed for "edit mode" (no additional mode label or overlay prompt).

---

### 4.6 Settings and Management UI

**FR-18 Entry Point**

The menu bar provides access to the management/settings interface.

**FR-19 Hotkey Configuration**

- The management UI allows configuring the set of hotkeys used to trigger recording (supports key combinations).
- Configuration changes take effect immediately.

**FR-20 LLM Configuration**

The management UI allows configuring LLM type/model, endpoint URL, API Key, and related parameters.

> **Note:** The specific range of configurable hotkeys and rules needs to be finalized at the product level (see Open Questions).

---

### 4.7 History Management

**FR-21 History List**

A history page is provided, displaying the user's past input records.

**FR-22 Retention Period**

Only the most recent week of records is retained (older entries are automatically purged on a rolling basis).

**FR-23 Record Content**

Each record includes:

- The original audio file (with playback support)
- The corresponding text content (final text)

**FR-24 Export and Clear**

The history page supports:

- **One-click export** (export scope/format to be determined)
- **One-click clear** (deletes local history records and associated audio files)

---

### 4.8 Audio File Requirements

**FR-25 Audio Format**

Audio files stored in history should use the MP3 format to balance file size and audio quality.

## 5. Non-Functional Requirements

### 5.1 Coding Standards (Mandatory)

**NFR-1 Clear Module Separation**

Code is organized into domain-based modules, such as: hotkey listening, audio capture, UI overlay, LLM client, text injection, clipboard, history storage and export, etc.

**NFR-2 Single Responsibility**

Each file and class follows the Single Responsibility Principle (SRP), with clear boundaries and low coupling.

**NFR-3 Comments and Maintainability**

Critical logic (system event listening, input injection, audio processing pipeline, streaming parsing, retry and error handling) must include necessary comments.

### 5.2 Security and Privacy (Current Phase Constraints)

**NFR-4 No Encryption**

History records and audio files will not be encrypted in this phase (encryption can be added in a future version).

### 5.3 Reliability and Compatibility (Strong Constraints)

**NFR-5 Universal App Compatibility**

"Compatible with all applications" is a high-priority goal. The technical design must define coverage strategies and degradation paths, ensuring that clipboard-based input remains available in the worst case.

## 6. Assumptions

- macOS allows implementing global hotkey listening (including Fn or alternative key combinations), audio recording, overlay display, and text injection targeting "all applications." If system limitations prevent injection in a few scenarios, the degradation strategy applies (clipboard is always available as a fallback).
- The OpenAI-compatible protocol server is available and configurable (Base URL, API Key, model, etc.).
- MP3 encoding can be performed locally or generated through an acceptable method (specific technical implementation to be determined in the technical design).
