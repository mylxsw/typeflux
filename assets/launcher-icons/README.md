# Launcher icon families

- **A / sculpted** is the default and initially installed family.
- **B / light** is bundled and ready for the next comparison.
- Both contain Chat, Translate, Screenshot, Recording, Notes, Word Book, Clipboard, and Settings.
- Only the first seven appear on the launcher's home. Settings artwork is reserved.
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
`launcherFeatureIconStyle`, with values `sculpted` and `light`. It applies to the entire family.

## Provenance

Original concept sheets and standalone transparent icon extractions were produced with the built-in
image generation tool. Extraction instruction: preserve each approved colored tile and foreground
symbol; remove board text/background and external shadow; keep internal shading and transparent
outer corners. Runtime PNGs are downsampled to 512 pixels for crisp rendering without decoding
full-size concept images. No code-generated approximation replaces the approved artwork.
