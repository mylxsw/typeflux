# Generated-image download recovery

## Evidence

The reported conversation retained a generated-image URL. A Foundation URLSession GET fetched its 4,745,474-byte PNG successfully in about two seconds. The installed media helper decoded it to a 1600 x 900 raster in 0.06 seconds. The recovered original is 2048 x 1152. Neither probe invoked image generation.

The running client recorded a 15-second request at 23:07:36 local time, failing five seconds later with NSURLError -1200, underlying TLS -9816, before receiving any bytes. The SDK defines -9816 as errSSLClosedNoNotify (peer closure without notification). This is consistent with the reported loading failure, but the OS redacts the failing URL, so it is not conclusive attribution to this particular image. A Python HTTP probe received a Cloudflare 1010 response while Foundation succeeded; that response was not treated as evidence of the client's failure.

## Change

Only the existing image GET retries once after a 300ms delay for timeout, lost connection, connection refusal, or the specific TLS peer-closure code. Other TLS and certificate errors, HTTP errors and decoding failures do not auto-retry. Cancellation and authorization checks remain between attempts. Normal certificate validation remains mandatory. No generation request is retried.

Failure cards now distinguish network/secure connection errors, HTTP status, unavailable previews, and decode/display failures. Content-free failure diagnostics retain error domains and codes without URLs or prompts. Explicit reload still retrieves only the existing image.

## Validation

Focused coverage selected AskRemoteImageTests, AskImageHTTPTests and AskFailureDiagnosticsTests (22 methods). All passed across the initial run and one focused retry. The new timeout fixture initially reached the lifecycle-owned preview gate before its fake network transport; injecting a test decoder isolates the intended network behavior. Only that method was rerun. Command wall times were 153.48s and 75.84s, including build/discovery. The final coverage report contains only the retry scope, not aggregate changed-line coverage.

The new cases check successful retry of the same GET, a two-attempt ceiling, rejection of certificate/HTTP retries, safe failure text and cancellation cleanup. Native application automation timed out; actual installed UI reload was not automated. The original image was recovered separately and visually inspected.
