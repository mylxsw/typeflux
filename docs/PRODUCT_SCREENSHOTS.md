# Product screenshot capture

The README and screenshot gallery share the 24 PNGs in `assets/product/`.
They are native production views rendered at Retina resolution, arranged on a
consistent presentation background. This is an isolated UI render, not a capture
of the developer’s desktop or a recording of live recognition.

`ProductScreenshotTests` is opt-in and excluded from ordinary execution unless
`TYPEFLUX_PRODUCT_SCREENSHOTS` is set. To regenerate from the repository root:

```sh
TYPEFLUX_PRODUCT_SCREENSHOTS="$PWD/assets/product" \
  /opt/homebrew/bin/python3 scripts/test_groups.py --suite ProductScreenshotTests
```

Use Python 3.11+ if that interpreter is installed elsewhere. The renderer needs
a macOS graphical session. Ring and translation photography use a window-only native capture
to preserve its glass material and requires Screen Recording permission for the
runner. Only the fixture window is captured. The remaining scenes render directly
from views. No microphone is used. The renderer never reads the system
pasteboard, personal conversations, or user file index. Preferences, conversation cache and sample files use temporary
locations. The launcher’s app, file and browser sources are test doubles.

The screenshot/recording subject is a fictional project brief drawn by the
fixture. Annotation tools, recording controls, clipboard, launcher, Ring and
voice overlays use production components. Recording controls use a fake capture
engine. Voice text is supplied by the fixture; no recognition request is made.
The bottom voice overlay is captured from its native controller. The corner and
island use their production views. Presentation backgrounds and the example
brief are illustrative, not additional Typeflux features.

Review every exported image for clipping, empty results, readability and sample
content before committing. Voice skins intentionally remain dark on both desktop
backgrounds. README images currently use Simplified Chinese interface text.

All Command monitors in fixture windows use an injected empty modifier state.
The capture asserts that those monitors are not showing shortcut hints; it does
not depend on whether the user is pressing Command during generation. This
changes only the photography fixture, not the app's shortcut behavior.

Translation uses the production panel with three hand-authored example results;
no translation provider is called. Chat uses the production workspace with a
synthetic conversation and sidebar history, isolated preferences and a signed-out
auth fixture. No personal conversation or account profile is used.
