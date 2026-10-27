# Launcher icon families

- **A / sculpted** is the default and initially installed family.
- **B / light** is bundled and ready for the next comparison.
- Both contain Chat, Translate, Screenshot, Recording, Notes, Word Book, Clipboard, and Settings.
- Only the first seven appear on the launcher's home. Settings artwork appears when searching its keyword.
- The application grid and the feature row both use seven columns.

The approved concept boards are preserved in `boards/`. Individual 512 × 512 transparent PNGs live in
`Sources/Typeflux/Resources/LauncherFeatureIcons/sculpted/` and `light/`.
Their globally unique filenames allow SwiftPM resource processing to flatten directories safely.

## Switch an installed build

From the repository root:

```sh
scripts/set_launcher_icon_style.sh A
scripts/set_launcher_icon_style.sh B
```

The script gracefully stops and reopens `~/Applications/Typeflux Dev.app`. No rebuild is needed.
An optional second argument selects another installed app. The preference key is
`launcherFeatureIconStyle`, with values `sculpted` and `light`. It applies to the original eight icons; extended keywords use A artwork in both modes.

## Provenance

Original concept sheets and standalone transparent icon extractions were produced with the built-in
image generation tool. Extraction instruction: preserve each approved colored tile and foreground
symbol; remove board text/background and external shadow; keep internal shading and transparent
outer corners. Runtime PNGs are downsampled to 512 pixels for crisp rendering without decoding
full-size concept images. No code-generated approximation replaces the approved artwork.

## Built-in keyword extension

The selected **A / sculpted** family now includes 45 additional icons (53 destinations total).
All built-in keywords, including system commands, resolve their artwork from plugin identity and
options rather than editable keyword spelling. Aliases share the same destination icon. Screenshot
modes, prompt presets, and search engines have distinct artwork. Custom workflow symbols, custom
prompts and custom web URLs retain their original fallback instead of borrowing a built-in identity.

The same mapping is used by keyword search, keyword hints, the `prefix` directory and input chips.
The original B comparison set stays intact; extended destinations fall back to A when B is selected.
`extended/generation.json` records the per-icon brief and shared generation prompt. Images were
individually generated using `boards/A-sculpted.png` as the style reference, then downsampled to
512 × 512 without changing their visual design. The source file manifest is in `extended/sources.json`.
