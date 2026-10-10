# Cron generator / reader

Generate schedules and explain Linux or Java / Quartz expressions.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `cron every 5 minutes` — Generate Linux and Java expressions.
- `cron weekdays 09:00` — Generate a weekday schedule.
- `cron */5 * * * *` — Explain a 5-field Linux expression.
- `cron java 0 0 9 ? * MON-FRI` — Explain Quartz, including L, W, # and optional year.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Linux uses 5 fields (minute, hour, day-of-month, month, weekday; Sunday 0/7). Java means Quartz: 6/7 fields (seconds first, optional year 1970–2099; Sunday 1). Use `linux` / `java` / `quartz` to pin the dialect; otherwise field count detects it. Quartz supports ?, L, L-n, W, LW, weekdayL and weekday#n, and requires exactly one ? in the two day fields. Linux restricted day-of-month and weekday are OR, and are explained separately. Supports standard Linux @aliases including @reboot. Generator commands: every N minutes/hours, daily HH:MM, weekdays HH:MM, weekly DAY HH:MM. Step intervals reset at field boundaries (every 7 minutes means */7, not seven elapsed minutes). Expressions are interpreted in the scheduler timezone; no jobs are installed and no future execution times are predicted.
