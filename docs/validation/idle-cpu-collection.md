# Collect remaining idle CPU evidence

The 2026-10-24 follow-up screenshot shows five Typeflux rows totaling about
27% CPU after the icon/preference correction. It does not identify their roles,
build, window visibility, or current stacks. The previous chat sample proves
the old icon hotspot; it cannot identify the remaining hotspot in a new build.

## Local collection

Update the repository, restart the local development app with the normal
workflow, and leave it untouched for two minutes. Keep its current window state
unchanged during collection. From the macOS client repository run:

```sh
python3 scripts/collect_idle_cpu.py
```

The command never starts, quits, or restarts Typeflux. It observes existing
packaged apps for four seconds, then samples each surviving process for three
seconds, up to ten processes. Five owners usually take about twenty seconds;
slow or inaccessible samplers can take longer. Keep using other apps to a
minimum during this period. Sampling itself adds overhead; compare the CPU
interval measured before sampling, rather than Activity Monitor during sampling.

Share the `.tar.gz` path printed at the end. Include whether a chat/launcher/
settings window was visible and the installed code revision, if known. The
archive contains owner/PID/executable/start-time mapping, CPU time deltas and
native stack samples. It excludes application logs, preferences, environment
variables and unrelated processes' command lines. Native samples contain local
paths and library names; review the archive before sharing. Files and archive
are private to the current user. Delete both temporary output and archive after
the investigation.

`intervalCPUPercent` is cumulative CPU time gained over measured wall time;
100 means one fully occupied core and values can exceed 100. It differs from
`reportedCPUPercent`, which macOS computes with its own averaging window. Null
means the process was newly observed or changed identity. Failed/exited samples
remain explicit in `processes.json`; they are not evidence of zero CPU.

## Remaining candidates

The launcher/chat empty-state orb has a 30 Hz timeline, the launcher grip has a
repeating animation, and the effort menu has a 30 Hz liquid fill. Inspect their
actual lifetime and visibility against fresh stacks before attributing CPU to
them. Other candidates include index jobs, preference-triggered work and status
publication. A screenshot alone cannot distinguish these. Do not sacrifice
speech-model readiness or input responsiveness to hide the symptom.

The collector is tested using synthetic process tables and fake sampling tools.
No remote development app or real feature process is launched for validation.

Validation: nine focused Python tests have successful final results. The initial
pass found one process-command matching failure; that method passed after the
fix, and the changed executable-identity test passed separately. Total command
wall times were 0.34 s, 0.46 s and 0.67 s. Standard-library trace counts cover
124/126 executable source lines (98.41%), combining matching unchanged lines
from the first pass with final-source method retries. This is collector coverage,
not Swift application coverage or proof of lower local idle CPU.
