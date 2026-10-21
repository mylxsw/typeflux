# Authenticated acknowledgement correction

The initial GUL-442 head `6fd3140576b569f7edcd3019545e548a66151d51` failed independent acceptance: an equal-content-revision usage update inherited the optimistic queued message during display reconciliation and incorrectly acknowledged it. A subsequent failed send lost the queued draft.

`accept` now retains the raw incoming API/engine response across cache/workspace awaits. Only that response reaches acknowledgement helpers, explicitly labelled `fromAuthenticated:`. Display/cache reconciliation still preserves optimistic messages and independent clocks. After suspension, account/session/deletion/operation guards are checked again before confirmation or advancement. A genuine confirmation still releases its current claim if another display update overtook the cache write.

Consumption and terminal policy are separate: `queueDidSettle` can apply the admitted run's terminal disposition, but passes no display transcript as consumption evidence. Raw authenticated transcripts deduplicate ordinary queued IDs and original-run supplements. Terminal supplement restoration requires admitted content revision/run/status agreement; historical usage clocks cannot restore an old terminal run over newer content.

## Caller audit

| Path | Confirmation evidence |
| --- | --- |
| `accept` / observation / drive | Raw API or local-engine response; projected snapshot is used only for presentation/state admission |
| `select` | Raw `api.conversation` result retained across cache save/load; cached/merged messages never acknowledge an item |
| Pending send resume/retry | Fresh `api.conversation` evidence or successful `api.send` response with matching conversation/message ID; existing pending request and original ID remain the only retry path |
| Steer response/error/retry | Raw response or fresh authenticated read, captured flight and original-run identity; consumption requires matching transcript run ID |
| Terminal/finish/explicit queue continuation | No display-message deduplication; terminal disposition uses admitted state and the existing freshness/blocker policy |
| Title/recovery/cancel callers | Existing API/engine return values enter `accept`; local projection/selection/cache values do not enter acknowledgement helpers |

The fixture checks `failSend` immediately after `beforeSend`, allowing an entered request to fail before server acceptance. Failed attempts are counted in `sends`; that list does not imply acceptance. The new held-send test covers Cloud/local routes, independent usage/recovery/budget updates, cache suspension, retained exact draft/ID, a second queued item, paused failure, and explicit idempotent retry followed by FIFO. The recovery-only terminal update retains the existing terminal freshness rule. An active replacement-run case also verifies that a recovery sequence is actually admitted without confirming the held request or replaying it into that run. A separate positive control suspends genuine acceptance in cache while a newer usage-only display arrives, then checks one release and no replay after a late transport error.

Final validation passed 147 methods; changed-line coverage is 479/486 (98.56%), with correction-only coverage 37/37 (100%). The README records commands, intermediate failures, hashes and portable recomputation. No full unit/UI suites or CI waiting are part of this correction.
