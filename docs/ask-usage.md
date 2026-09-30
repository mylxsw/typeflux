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

Context estimates describe saved request content, not the unsent draft. Model
changes update the capacity and reserve; provider-specific tokenization remains
an estimate. Earlier messages replaced by a summary are excluded from the input
budget, but remain in history and cumulative usage.
