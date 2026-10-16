# Self review

The path reviewed is authorized file metadata → verified private snapshot → local Vision → bounded UTF-8 frames → private text/visual segments → final version/permission/cancellation check → atomic chunks/FTS publication → lexical or modality-aware vector evidence. Existing document-first checkpoints and idle gating are retained before each text batch; no external resources are read from screenshot contents.

Corrections made during implementation/review:

- Compare the completed image job recipe against the combined visual/OCR recipe, so reopening the store does not repeatedly queue completed images. Include legacy published images without durable job rows.
- Copy only exact same-version, same-model/projector visual segments into upgraded jobs. Private text batches require matching generation, offsets and exact text before skipping inference.
- Treat OCR text vectors as text in vector provenance checks and calibration, while preserving the original image segment. Separate synthetic vectors verify each result source.
- Normalize reader cancellation to `CancellationError`, check cancellation after inference and before staging, and recheck after final metadata reads. The prior test expecting a result completed after cancellation to be staged was corrected.
- Bind the blank-image flag as an integer; the existing SQLite binder does not support Bool. Blank images retain their visual result with `image-no-text`; OCR exceptions preserve visual results with a fixed retryable reason.
- Keep staging tables under the media-job foreign key, with transactional publication and cascading cleanup. File descriptors, ImageIO decoders and worker ownership remain within existing scopes.

Checked cancellation/resume, stale generations, file replacement, permission withdrawal, no-text/corrupt input, recipe upgrade/reopen, query source/version/offset consistency, image/text model provenance, scratch permissions and cleanup, and documentation consistency. No keys, tokens or personal fixtures are introduced. Tests use local synthetic fixtures and deterministic embedding vectors.

The added direct-worker test initially referenced a snapshot folder already removed after successful publication. Only the test was corrected to use its still-owned failure folder; the minimal failed method was retried. A pre-existing closure formatting warning in the touched media test was corrected, and the intentionally cohesive integration suite has a scoped type-length lint exception.
