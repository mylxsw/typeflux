# Ask usage

The usage panel adds controls outside the existing composer. The composer, voice
input, attachments, model picker and keyboard behavior are unchanged.

Conversation content and usage have independent revisions. Usage must be merged
without replacing a newer content snapshot. The local cache preserves the newer
usage version when a delayed response contains older metering.

Cloud amounts come from the API's existing billing recorder in microcredits.
Own API reports include tokens only and never authorize Cloud billing. A pending
or missing value is not zero. Totals include all calls in a run, including summaries
and tool decisions; each assistant message links to its run's aggregate.

Local conversations persist provider-reported tokens and invocation details next
to their history, including summaries, failures and cancelled calls. The panel
shows tokens instead of credits and reads local records without a Cloud session.
Duplicate receipts are counted once; late usage can update a recorded invocation
without changing a completed or replacement run. Missing or partial reports stay
unknown or a lower bound. Older conversations still load, with a historical gap
when metering starts; tokens from calls made before metering cannot be recovered.

Context estimates describe saved request content, not the unsent draft. Model
changes update the capacity and reserve; provider-specific tokenization remains
an estimate. Earlier messages replaced by a summary are excluded from the input
budget, but remain in history and cumulative usage.
