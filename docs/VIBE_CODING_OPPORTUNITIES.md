# Vibe Coding Opportunity Analysis

Date: 2026-05-11
Issue: TYP-97

## Executive Summary

Large vendors are moving voice input into their own AI products, so Typeflux should not compete as a generic dictation utility. The more defensible position is:

> Typeflux is the macOS voice control layer for AI coding workflows.

That means Typeflux should optimize for developers who already live inside Cursor, VS Code, JetBrains, terminals, Claude Code, Codex, and other agent tools. The wedge is not "speech to text anywhere"; it is "turn rough spoken intent into accurate, context-rich coding instructions and route them into the right coding surface."

This is a good fit for the current codebase. Typeflux already has system-wide text injection, local and cloud STT routing, streaming preview, selected-text edit flows, app-aware personas, automatic vocabulary collection, history, Ask mode, an agent router, and MCP-related hooks. The opportunity is to compose those primitives into a vertical coding mode rather than build a separate product from scratch.

## Market Signals

Current market movement shows three important trends:

1. Voice is becoming native inside major AI coding and AI assistant tools.
2. Several independent apps are already competing on fast, local, system-wide dictation.
3. The more interesting frontier is voice plus coding context plus agent orchestration.

Relevant public signals checked on 2026-05-11:

- Claude Code now has voice dictation that is tuned for coding vocabulary and injects text at the cursor in the CLI prompt. It is app-scoped and server-transcribed through a Claude.ai account. Source: https://code.claude.com/docs/en/voice-dictation
- Claude Desktop Quick Entry on Mac includes voice dictation, screenshots, and window context from any app, but the final destination is Claude Desktop. Source: https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac
- OpenAI's Codex app positions itself as a command center for multiple coding agents, long-running tasks, isolated worktrees, progress, decisions, reusable skills, and automations. Source: https://openai.com/index/introducing-the-codex-app/
- Cadence positions around on-device transcription, system-wide insertion, and voice direction of multiple Claude assistants. Source: https://www.cadencevoice.ai/
- Spokenly is explicitly pushing voice dictation through MCP for Claude Code, Codex CLI, Cursor, and other MCP-compatible agents. Source: https://spokenly.app/blog/voice-dictation-for-developers
- Dictto includes Claude Code integration, custom dictionaries, local Whisper, and a voice-agent hotkey. Source: https://dictto.app/
- VoiceInput positions around local history and private searchable memory for all dictation. Source: https://voiceinput.app/en/

The conclusion: generic dictation is crowded and structurally hard to defend. Coding-specific voice workflows are still fragmented, because each tool only owns one surface and cross-tool context is poor.

## Typeflux Starting Assets

Typeflux has several existing capabilities that map well to this vertical:

- System-wide macOS insertion through Accessibility and paste fallback, documented in [Usage Guide](./USAGE.md) and implemented under `Sources/Typeflux/TextInjection`.
- Local-first STT architecture with WhisperKit and Sherpa-ONNX runtimes, documented in [Local Model Architecture](./LOCAL_MODEL_ARCHITECTURE.md).
- Multiple remote STT providers, including realtime preview backends and multimodal LLM transcription.
- Ask mode and an agent workflow that can route spoken requests to answer, edit, or multi-step agent execution.
- App-aware persona resolution via `SettingsStore.effectivePersona`.
- Input context capture in `AXTextInjector`, including focused app metadata, selected text, visible text, document text, clipboard-adjacent workflows, and application state fallbacks.
- Automatic vocabulary collection that can learn corrections after successful insertion.
- MCP settings and agent tool paths already present in the codebase.

Those are strong primitives. The missing layer is a productized coding profile that understands developer intent, target app capabilities, code symbols, and agent task quality.

## Strategic Positioning

### What We Should Not Be

- Not another universal dictation app competing on "hold a key and paste text."
- Not a single-agent wrapper around Claude Code or Codex.
- Not a cloud-only speech product.
- Not an IDE plugin that only works in one editor.

### What We Should Be

Typeflux should be an agent-agnostic coding voice layer with four promises:

1. Speak naturally; Typeflux turns the utterance into a coding-grade instruction.
2. Typeflux knows where you are: terminal, IDE, browser, chat, selected code, current app, and project hints where available.
3. Typeflux routes the result to the right surface: dictation, edit selected code, ask/explain, or command an AI coding agent.
4. Typeflux learns your project names, symbols, dependencies, commands, and correction patterns locally.

This gives Typeflux a reason to exist even when Claude, OpenAI, Apple, and IDE vendors all ship voice input. Their voice features are attached to their own surfaces. Typeflux can be the cross-surface workflow layer.

## Opportunity Areas

### 1. Coding-Grade Dictation

Most STT systems handle prose better than code-adjacent speech. Developers need exact symbols, casing, filenames, CLI flags, framework names, and mixed Chinese/English terminology.

Product opportunities:

- Add a "Coding" input profile that post-processes transcripts into code-friendly text.
- Support spoken symbol grammar: "open paren", "close brace", "slash", "dot env", "dash dash help", "camel case user id", "snake case access token".
- Preserve technical casing: `OAuth`, `JSON`, `URLSession`, `UserDefaults`, `AGENTS.md`, `swift test --filter`.
- Use project vocabulary as STT hints and rewrite constraints.
- Add language-aware cleanup for Chinese-English coding speech, for example preserving English identifiers inside Chinese instructions.

Architectural implication:

- Add a `CodingDictationNormalizer` behind the existing workflow after STT and before optional persona rewrite.
- Keep it provider-independent. Local and cloud STT should both feed the same normalization path.

### 2. Voice-to-Agent Prompt Compiler

The strongest wedge is not raw transcription. It is converting messy spoken intent into prompts that coding agents can execute reliably.

Developers often say:

> "Fix the settings thing from before, make sure the tests cover the failure path, and do not break the onboarding screen."

A coding agent needs:

- Goal
- Scope
- Relevant files or app context
- Constraints
- Acceptance criteria
- Verification command
- Expected output format

Product opportunities:

- Add a "Prompt Compiler" mode for AI coding tools.
- Convert raw speech into structured instructions for Claude Code, Codex, Cursor, Aider, OpenCode, or GitHub Copilot-style chat.
- Generate acceptance criteria automatically when the user says "fix", "refactor", "add", "review", or "test".
- Offer a live structured preview before insertion or auto-submit.
- Detect uncertainty and ask one short clarification instead of sending vague prompts.

Architectural implication:

- Add a `CodingPromptCompiler` service with a typed request and response model.
- Reuse `LLMAgentRouter` and `AgentPromptCatalog`, but separate the concern from generic Ask mode so coding-specific routing can evolve without bloating the general assistant.

### 3. Target-Aware Routing

Different coding surfaces want different output:

- Terminal Claude Code or Codex CLI: insert a concise command prompt, optionally submit.
- Cursor or VS Code chat: insert a structured instruction with file references.
- Editor text field: insert code or edit selected text.
- Browser issue tracker: draft a bug report, PR description, or review comment.
- Typeflux Ask answer window: answer without changing the target app.

Product opportunities:

- Detect the focused app and classify it as editor, terminal, browser AI chat, issue tracker, or generic text field.
- Provide per-target output templates.
- Add optional auto-submit only for trusted coding-agent targets and only after visible preview.
- Use app bindings to default personas and coding profiles per target app.

Architectural implication:

- Introduce a `CodingTargetAdapter` protocol:
  - `matches(appContext:)`
  - `defaultMode(for:)`
  - `formatCompiledPrompt(_:)`
  - `submissionPolicy`
- Keep target adapters thin. The workflow controller should not become a pile of app-specific conditionals.

### 4. Context Packets for Coding Agents

Voice alone is ambiguous. Typeflux can differentiate by attaching the right context.

Existing context capture already includes selected text, app metadata, visible text, document text, and application state fallbacks. For coding, we can package that context explicitly.

Product opportunities:

- Include selected code and surrounding visible text when asking for edits or explanations.
- Include terminal command output when the target is a terminal.
- Include file path, project name, git branch, and package manager hints when safely detectable.
- Add a manual "attach clipboard" or "attach screenshot" command for ambiguous UI bugs.
- Support "this error", "this file", "this selected function", and "the failing test" as first-class references.

Architectural implication:

- Add a `CodingContextPacket` model that is built from existing `InputContextSnapshot` and optional project detectors.
- Treat repo and terminal context as permissioned data. Prefer explicit toggles and visible indicators for sensitive context capture.

### 5. Project Vocabulary and Symbol Memory

Typeflux already has automatic vocabulary collection. Coding creates a better source of vocabulary than general writing because project identifiers are structured.

Product opportunities:

- Scan project files for identifiers, filenames, package names, test names, route names, and common commands.
- Learn from manual corrections after dictation.
- Keep vocabularies scoped by project, app, or repo root.
- Use vocabulary for both STT hints and post-processing.
- Surface a "Coding Vocabulary" panel with editable learned terms.

Architectural implication:

- Extend `ProjectVocabularyScanner` and `VocabularyStore` into scoped vocabularies.
- Add source metadata such as `projectScan`, `manual`, `automaticCorrection`, and `agentFeedback`.

### 6. Voice Review and PR Workflows

Coding voice input is not only for writing code. It is also useful for review, triage, and explanation.

Product opportunities:

- Select a diff or code block and say "review this for architecture risk"; Typeflux produces a structured review.
- Dictate PR descriptions from the current git diff or selected issue.
- Generate test plans from spoken implementation notes.
- Turn a rough bug report into reproduction steps and acceptance criteria.
- Let architects and senior engineers produce high-quality review comments without leaving the code surface.

Architectural implication:

- Add coding templates for `review`, `bug_report`, `test_plan`, `pr_description`, and `architecture_note`.
- These are prompt compiler output types, not separate workflows.

### 7. Cross-Agent Voice Orchestration

Large tools own their own agents. Typeflux can remain model- and agent-agnostic.

Product opportunities:

- Route prompts to the user's chosen agent surface: Claude Code, Codex CLI/app, Cursor, or a generic MCP endpoint.
- Add voice commands such as "send this to Codex", "ask Claude to review", or "put this in Cursor chat".
- Support named target bindings rather than hard-coded vendor assumptions.
- Use MCP where the target supports it, and fall back to system-wide insertion where it does not.

Architectural implication:

- Keep direct integrations optional.
- Prefer local adapters and MCP over cloud account coupling.
- Do not make Typeflux dependent on one AI vendor's API or authentication model.

## Recommended Product Bets

### Bet 1: Coding Mode MVP

Goal: make Typeflux materially better than generic dictation for developers within two weeks.

Scope:

- Add a Coding persona/profile.
- Add coding vocabulary defaults and symbol grammar.
- Add target detection for Terminal, iTerm, Warp, VS Code, Cursor, JetBrains, and browser AI chats.
- Add a structured prompt compiler for agent instructions.
- Add a preview step for compiled prompts.

Success metric:

- A developer can dictate a Claude Code or Codex prompt that is clearer than the raw transcript in at least 8 out of 10 common coding scenarios.

### Bet 2: Agent Prompt Compiler

Goal: become the best voice-to-agent prompt tool, not just a transcription tool.

Scope:

- Typed compiler output: `intent`, `target`, `instruction`, `context`, `constraints`, `acceptanceCriteria`, `verification`.
- Templates for implement, fix, refactor, test, review, explain, and document.
- Clarification policy for underspecified requests.
- Per-target formatting.

Success metric:

- Agent prompts generated by Typeflux require fewer follow-up corrections than manually dictated raw prompts.

### Bet 3: Project Vocabulary and Context

Goal: improve recognition and prompt quality with local, project-specific context.

Scope:

- Scan project identifiers and filenames.
- Detect repo root and branch for terminal/editor targets.
- Feed terms into STT hints and post-processing.
- Show scoped vocabulary in settings.

Success metric:

- Measurable reduction in corrections for project names, filenames, framework names, acronyms, and commands.

### Bet 4: Voice Review Toolkit

Goal: serve senior developers and architects who spend more time reviewing than typing code.

Scope:

- "Review selected code"
- "Turn this into a PR comment"
- "Write the test plan"
- "Explain architecture risk"
- "Summarize this diff"

Success metric:

- Review comments are structured, specific, and paste-ready without manual cleanup.

## Architecture Direction

Recommended module additions:

```text
Sources/Typeflux/Coding/
  CodingMode.swift
  CodingIntent.swift
  CodingDictationNormalizer.swift
  CodingPromptCompiler.swift
  CodingPromptTemplate.swift
  CodingTargetAdapter.swift
  CodingContextPacket.swift
  CodingVocabularyProvider.swift
```

Recommended integration points:

- `WorkflowController+Processing.swift`: call coding normalization or prompt compilation after STT based on mode and target.
- `WorkflowController+Agent.swift`: reuse agent routing for multi-step tasks, but avoid mixing coding prompt compilation into generic Ask semantics.
- `SettingsStore.swift`: add coding mode preferences, app bindings, and scoped vocabulary flags.
- `AXTextInjector.swift`: continue as the source of app and selection context, but expose coding context through typed snapshots.
- `PromptCatalog.swift` or a new `CodingPromptCatalog.swift`: keep coding-specific prompts isolated.

Architectural standards:

- Provider-agnostic: no feature should require a single STT or LLM vendor.
- Target-adapter based: app-specific formatting belongs in adapters, not the workflow controller.
- Privacy-forward: repo, terminal, clipboard, and screenshot context must be opt-in or visibly controlled.
- Preview-before-action for agent auto-submit: compiled prompts should be reviewable before Typeflux presses Enter.
- Local-first where possible: project vocabulary, context extraction, and correction memory should run locally.

## Risks and Mitigations

| Risk | Why It Matters | Mitigation |
|------|----------------|------------|
| Big vendors copy voice features | Generic dictation will be commoditized | Differentiate on cross-tool workflow, local context, and vendor-neutral routing |
| Prompt compiler over-edits user intent | Developers will lose trust if Typeflux changes meaning | Provide preview, preserve raw transcript, and make compiler output structured |
| Context capture feels invasive | Coding context can contain secrets | Opt-in project context, local processing, visible indicators, and redaction controls |
| App detection becomes brittle | macOS apps expose inconsistent Accessibility data | Use target adapters with graceful fallback to generic insertion |
| Scope creep into building an IDE | Typeflux should remain a voice layer | Integrate with existing tools instead of replacing them |
| Agent integrations change quickly | APIs and CLIs evolve | Use MCP and insertion adapters first, vendor SDKs second |

## Suggested Roadmap

### Phase 1: Coding Mode Foundation

- Define `CodingMode`, `CodingIntent`, and target categories.
- Add coding persona/profile and symbol grammar.
- Add prompt compiler MVP for implement, fix, test, review, and explain.
- Add target detection and per-target formatting.
- Add tests for transcript-to-compiled-prompt behavior.

### Phase 2: Project Context and Vocabulary

- Add project vocabulary scanning for common repo roots.
- Scope vocabulary by app/project.
- Feed project terms into STT hints and coding normalization.
- Add settings UI for coding vocabulary review.

### Phase 3: Agent Routing and MCP

- Add target adapters for Claude Code, Codex CLI, Cursor/VS Code chat, and generic MCP.
- Add optional auto-submit policies.
- Add voice commands for named destinations.

### Phase 4: Review and Team Workflows

- Add review, PR description, bug report, and test plan templates.
- Add diff and terminal-output context where safely available.
- Add exportable history for coding sessions.

## Immediate Next Actions

1. Build a Coding Mode MVP around prompt compilation rather than raw dictation.
2. Create a small benchmark set of 30 spoken coding scenarios covering English, Chinese, mixed speech, symbols, filenames, CLI commands, and agent instructions.
3. Implement target adapters behind a protocol before adding app-specific behavior.
4. Keep this vertical vendor-neutral: Claude Code, Codex, Cursor, terminals, and browsers should all remain first-class targets.
