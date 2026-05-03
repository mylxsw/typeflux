# Typeflux Scenario-Behavior Reference Table

This document describes the trigger conditions and corresponding system behaviors for the Typeflux application across various scenarios.

## Hotkey Operation Scenarios

| Scenario | Behavior |
|----------|----------|
| Hold-to-talk mode | User holds the activation hotkey (default FN) → recording starts, floating recording capsule appears, start sound effect plays |
| Tap-to-lock mode | User quickly taps the hotkey (<220ms) → enters locked recording mode, overlay shows confirm/cancel buttons |
| Hotkey release (short press) | Hotkey released with hold duration <220ms → switches to locked recording mode |
| Hotkey release (long press ends) | Hotkey released with hold duration ≥220ms → recording stops, post-processing begins |
| Ask hotkey triggered | Ask hotkey pressed (⌘⇧Space) → starts locked recording for querying selected text |
| Persona selection hotkey triggered | Persona hotkey pressed (⌘⇧P) → displays the persona selector overlay |

## Persona Selector Scenarios

| Scenario | Behavior |
|----------|----------|
| Switch default persona | Open persona selector with no text selected → allows switching the global default persona |
| Apply persona to selection | Open persona selector with text selected → applies persona directly to the selected text |
| Persona selection confirmed | Press Enter or click in the persona selector → applies the selected persona |
| Persona selection cancelled | Press Esc or click outside → closes the persona selector without applying changes |

## Recording Control Scenarios

| Scenario | Behavior |
|----------|----------|
| Recording timeout (10 min) | Recording reaches the 10-minute limit → automatically stops and processes the audio |
| Recording too short | Recording duration <0.35 seconds → processing cancelled, displays "Recording too short" prompt |
| No voice signal detected | Audio analysis finds no audible signal → processing cancelled, displays "No speech detected" prompt |
| Audio device initialization failed | Recording device failed to initialize → logs error, plays error sound effect, shows failure prompt |
| User cancels recording | Press Esc or click the cancel button → stops recording, clears state, closes the overlay |
| Confirm locked recording | Click confirm or press hotkey in locked mode → stops recording and begins processing |

## Voice Processing Scenarios

| Scenario | Behavior |
|----------|----------|
| Speech recognition | STT Router transcribes the audio → displays processing status, supports real-time preview |
| Empty transcription result | Transcribed text is empty → skips subsequent processing, displays a prompt |
| Persona rewrite mode | Persona enabled and transcription succeeded → calls LLM to rewrite text using the persona prompt |
| Selection edit mode | Text is selected when recording → LLM edits the selected text based on the instruction |
| Ask answer mode | Ask hotkey used with text selected → enters Agent workflow, decides whether to answer or edit |
| Agent answer result | Agent decides to answer the question → opens AskAnswer window to display the response |
| Agent edit result | Agent decides to edit text → writes the edited text back to the original location |
| Multimodal model direct processing | Multimodal STT used and no rewrite needed → skips LLM rewriting, applies transcription result directly |
| Processing timeout (2 min) | Processing exceeds 2 minutes → cancels processing, displays timeout failure prompt with retry option |
| User cancels processing | Press Esc during processing → cancels the current processing task, records failure status |
| Retry from history | Click retry in history record → reprocesses the audio for that record |

## Text Injection Scenarios

| Scenario | Behavior |
|----------|----------|
| Replace selection | Target is editable with text selected → uses AX API or Cmd+V to replace the selected text |
| Insert text | Target is editable with no text selected → inserts text at the cursor position |
| Text injection failure fallback | Both AX API and paste fail → displays result dialog with a copy button |
| Permission check failed | Attempting text injection without Accessibility permissions → opens the System Settings permissions page |
| Clipboard restoration | After injecting text via paste → delays restoring the original clipboard contents |

## Overlay UI Scenarios

| Scenario | Behavior |
|----------|----------|
| Recording capsule | While recording → displays volume waveform animation |
| Recording preview | When real-time transcription is available → shows transcribed text preview below the capsule |
| Processing state | During transcription or LLM processing → displays progress animation and status text |
| Failure prompt | On processing error → displays error message with optional retry button (if retryable) |
| Result dialog | When text cannot be injected directly → displays result with a copy button |
| Persona selector | Displays persona list → supports ↑/↓ arrow key navigation, Enter to confirm, Esc to cancel |

## System Feature Scenarios

| Scenario | Behavior |
|----------|----------|
| Automatic vocabulary collection | After successful text injection → monitors input field changes, detects user corrections, and automatically learns vocabulary |
| Menu bar status update | On state change → updates menu bar icon and menu content |
| Settings window operations | Click a menu item → opens settings window to the corresponding page (Home/History/Persona) |
| First-launch onboarding | Onboarding not completed → opens the permissions guidance window |
| Local model warm-up | When using local STT → preloads the model in the background to reduce latency |
| MCP tool invocation | Agent mode with MCP enabled → calls external MCP server tools |
| Skill system invocation | Agent detects a skill match → loads the corresponding skill prompt and tools |

## Hotkey Reference

| Hotkey | Function |
|--------|----------|
| `FN` (default) | Hold to talk / Tap to lock |
| `⌘⇧Space` | Ask mode (query selected text) |
| `⌘⇧P` | Open persona selector |
| `Esc` | Cancel recording / processing / close overlay |
| `↑/↓` | Navigate up/down in persona selector |
| `Enter` | Confirm persona selection or lock recording |

## Core Workflow

```
Hotkey trigger → Start recording → Audio analysis → Speech recognition → [Optional] LLM processing → Text injection → Done
                    ↓                  ↓                ↓                      ↓
               Overlay display    Check audio       Streaming preview    Fallback to result
               real-time preview  too short/silent   real-time transcript  dialog on failure
```

## State Transitions

| Current State | Possible Next State | Trigger |
|---------------|-------------------|---------|
| Idle | Recording | Hotkey pressed |
| Recording | Processing | Hotkey released (recording ends) |
| Recording | Idle | Esc pressed (cancel) |
| Processing | Idle | Processing completed and text injected successfully |
| Processing | Result dialog | Text cannot be injected directly |
| Processing | Failure prompt | Processing error occurred |
| Processing | Idle | Esc pressed (cancel) / Timeout |
