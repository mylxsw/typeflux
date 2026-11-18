# Generated image disk cache

Generated image presentation now persists validated original bytes in the application cache directory. A SHA-256 key covers the account and immutable asset ID, without storing a signed URL or account identifier in filenames. Reopening a conversation, restarting the app or refreshing a signed URL can reuse the original offline. Every disk hit is still decoded by the isolated media worker; access checks and view revocation remain in place.

Missing or unreadable/corrupt cached bytes fall back to the existing bounded GET. Preview-service unavailability does not destroy a valid file. Downloads of the same account/asset are coalesced within one presentation process; cancelling one caller does not stop another, while the last departing caller cancels the download. Separate processes may download independently, but disk mutations are protected with a shared file lock.

The cache is globally limited to 256 MiB, evicting least-recently-used files. Atomic writes use private file permissions. Clearing rotates a disk epoch, preventing in-flight requests in any process from repopulating the cleared cache. Cache storage failure does not prevent displaying a downloaded image. Cache settings show disk usage and clear only local cached copies. Existing displayed pixels are not revoked by disk cleanup. Account changes isolate access; local cached copies may remain until cleanup/eviction.

Reload prefers local bytes; the separate Download again action bypasses the disk hit without deleting a good original when the network fails. It never calls image generation. The explicit-download flag is consumed before awaiting the task so an older cancelled task cannot overwrite a newer request.

## Validation

The initial focused coverage run selected AskGeneratedImageCacheTests, AskRemoteImageTests, AskImageHTTPTests and the advanced image-settings render test: 24 methods passed in 205.02 seconds including compilation/discovery. Cache source line coverage was 98.64%; remote image source line coverage was 91.91% in that run. These are file metrics, not changed-line or whole-project coverage.

After the explicit-download state refinement, the directly affected view test and settings render passed in 59.52 seconds. Visual review found missing section padding; after matching existing settings padding and buttons, only the settings render was repeated (60.25 seconds, passed). Final coverage output represents that last narrow scope rather than a combined report. Native rendering verified the cache section layout; its capture is in `validation/generated-image-cache-2026-11-18/`. Installed-app offline interaction and live downloads were not automated.

Tests cover persistence through a new cache instance, offline cache hits, account isolation, forced downloads, corrupt-byte recovery, concurrent GET sharing, cancellation, capacity eviction, and cross-instance clear invalidation. No paid image request was submitted. The local development app uses the debug configuration for this update.
