# Onboarding v3 design spec (GUL-634)

Source of truth: `prototype.html` in this directory. Open it in a browser. The **页面** chips switch pages and the **状态** chips switch states. The approved states for each page are also captured in `0-welcome.png` … `7-try.png`. If this text and the prototype disagree, the prototype wins.

## Copy rules (mandatory)

- Avoid unnecessary secondary labels and descriptions. Let the layout do the explaining.
- Avoid unnecessary supporting text, descriptive copy, and redundant UI microcopy.
- One title and at most one short subtitle per page. Status words are short: 可用 / 已授权 / 已下载 / API Key 无效. An error is one line, placed next to what failed.
- Do not add strings that the prototype does not show. Remove superseded `onboarding.*` / `setup.*` strings in every language.

## Flow

```
welcome → route ─┬─ cloud ─────────────┐
                 ├─ speech → llm ──────┼→ permissions → shortcuts → try
                 └─ (暂不连接, confirm) ─┘
```

The step pill reads `01 / 04` for route, cloud, speech and llm, `02 / 04` for permissions, `03 / 04` for shortcuts and `04 / 04` for try. Welcome has no pill. The five feature guide pages and the finish page are removed and replaced by **try**. Skips, deferral and recovery work as they do today: the menu bar's "继续设置…", `onboarding*Deferred`, and existing configuration is preserved.

## Visual language (from v0.4.0 `OnboardingView`)

| Element | Spec |
|---|---|
| Window | 960 × 664 pt. Background is a diagonal gradient with a 460 pt accent glow in the top-right corner (accent 0.16 opacity in dark, 0.10 in light). The title bar shows only the traffic lights: no app icon or name. |
| Header | Eyebrow: 9.5 pt semibold, uppercase, tracking 1.6, accent colour. Title: 30 pt bold. Subtitle: 13 pt secondary. Step pill top-right: 10 pt semibold capsule. Route and cloud headers are centred; all other pages are left-aligned. Horizontal inset 34 pt. |
| Footer | Floating bar, inset 20 pt from the sides and 18 pt from the bottom, 58 pt tall, corner radius 20. Back: secondary capsule button with ← icon, 38 pt. Primary: accent capsule, 38 pt, bold, with → icon. Tertiary (稍后 / 跳过 / 改用自己的模型 / 使用默认): plain text. Any hint sits to the left, 11.5 pt tertiary. |
| Cards | Radius 18, 1 pt subtle stroke. A selected card gets a highlight fill, a selected stroke and an outer accent ring offset 3 pt (1.2 pt wide), plus a radio dot. |
| Provider card | 38 pt white logo plate (radius 12) using `Resources/Providers/*.png`, or the Typeflux logo. Title 13.5 pt semibold, one line of 11 pt description, a 9 pt uppercase badge capsule, then the radio dot. |
| Config panel | Card with eyebrow `CONFIGURATION`, provider plate + 18 pt bold name, 12 pt description, labelled fields (34 pt tall, radius 10). A pinned bottom row holds "获取 API Key ↗" on the left and the test button on the right. The result strip shows the preview + latency, or a one-line error. |

## Pages

- **route:** two 156 pt art cards. Cloud: brand glow + Typeflux orb + capability chips. Own models: a mosaic of real provider logos. Select, then 继续 (double-click also continues). "暂不连接，先用启动器" is a tertiary link that opens a confirmation alert.
- **cloud:** a centred 460 pt card. Uses the existing web login (`WebLoginCoordinator`): browser → waiting (重新打开 / 取消) → exchanging → signed in. Failures and cancellation show inline. **No success NSAlert while onboarding.** Once signed in, the card shows the account row (avatar, name, email, plan badge) and the 语音识别 / AI 模型 availability rows. If the plan has no cloud speech: 改用本地模型, with download progress inline.
- **speech / llm:** a 330 pt provider list on the left (scrolls, fades at the bottom) and the config panel on the right.
  - Speech providers follow `STTProvider.onboardingDisplayOrder`.
  - The local model is chosen from a menu following `LocalSTTModel.displayOrder` with sizes, and downloads inline.
  - The speech test is press-and-hold (`按住说话测试`). The first test triggers the system microphone prompt.
  - Google speech-to-text: 使用 Google 授权 ↗, then a `Project ID` field (reusing the Settings key). Test needs both. (Decision on GUL-638.)
  - LLM shows 免费模型, OpenAI, Anthropic, Gemini, DeepSeek, 通义千问, OpenRouter and Ollama, plus a "更多服务商" menu for the remaining `LLMRemoteProvider` cases and the custom endpoint.
  - Pasting a key auto-validates and fetches the model list.
  - Replaces the 820 × 550 `StudioView` sheet.
- **permissions:**
  - **必需** section: microphone and accessibility, plus speech recognition when Apple Speech is selected, with an `x / n` badge. Only the next pending row has the accent button. 继续 requires all required permissions.
  - **可选** section: collapsed into one row with an `x / 6` badge (`SettingsPermission` minus the core ones). Expanded, it shows one row per permission with its action.
  - Panes that need System Settings show the floating guide (bottom-right) and auto-detect.
  - A denied permission switches to 打开设置.
- **shortcuts:**
  - Grid in two groups. 语音: 语音输入, 辅助语音输入, 人设切换. 常用工具: 启动器, 圆环, 剪贴板, 截图, 翻译.
  - Click a keycap to record; Esc cancels.
  - The ⋯ menu offers 录制新快捷键 / 恢复默认 / 清除; voice input also gets the fn / 右 ⌘ / 右 ⌥ presets.
  - Conflicts show inline on the card: system ones from `SystemSymbolicHotkeys` (e.g. ⌘Space vs Spotlight, with a one-click alternative) and internal ones from `HotkeyConflictChecker`. An fn emoji conflict shows "去修改" plus the floating guide.
  - Footer: "全部恢复默认" and "使用默认".
- **try:** a feature list on the left using the live bindings, and a practice area on the right. Features with no AI connected show 连接.

## Acceptance

Native captures of every page and state, in both appearances and in Chinese and English, compared side by side with the prototype states. No truncation and no extra copy. Focused tests for every changed behaviour, per `CLAUDE.md`.
