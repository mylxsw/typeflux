# Launcher calendar

Type `cal`, `日历`, `rl`, or `calendar` and press Return. A space after the keyword enters immediately. The calendar uses the launcher's existing window and the system's time zone and first weekday.

The approved design is in [proposal #467](https://github.com/mylxsw/typeflux/pull/467). The native implementation provides a fixed six-week month grid, lunar dates and festivals, solar terms, holiday and makeup-workday badges, daily events, date intervals, year navigation, and event search.

## Input and shortcuts

Examples: `12-25`, `2027/2/7`, `明天`, `下周五`, `+30`, `+2w`, `春节`, `冬至`, `2026-12`, `2027`, `今天到12-31`, and `review`. English expressions include `today`, `tomorrow`, `next fri`, `dec 25`, and `christmas`. Invalid numeric dates are shown as errors. Supported years are 1901–2099.

| Key | Action |
| --- | --- |
| Arrow keys | Select a day; horizontal arrows retain normal cursor behavior when input is present |
| Command + Left/Right | Change month, clamping to the last day when necessary |
| Command + T | Today and clear input |
| Tab | Switch between dates and events; return from a search result to its date |
| Return | Open date/event, join a recognized meeting, enter the selected month, or copy an interval |
| Command + O | Open the selected event in Calendar |
| Command + N | Open the selected date in Calendar for creating an event |
| Command + C | Copy the date, selected event, or interval without closing |
| Option + Return | Insert the date into the source application using the existing delivery pipeline |
| Escape | Leave event focus, clear input, leave the keyword, then close the launcher |

Event search covers the previous 30 days through the following 90 days. It matches title, location, and calendar name. Calendar events are read locally using EventKit. The app never creates or edits events. New and edited events remain the responsibility of the macOS Calendar app.

Calendar access is requested only from the explicit permission button. Denial leaves date features available and offers System Settings. Hiding the permission card persists `calendar.events=false` in that keyword's options; re-enable it in Settings → Launcher → Keywords → Calendar. The same editor controls lunar information, mainland China holidays, ISO week numbers, included calendars, and copied date format. Holiday subscription calendars are excluded by default when the built-in mainland China holiday schedule is enabled; ordinary personal calendars remain included.

## Data and maintenance

- Lunar dates use Foundation's Chinese calendar, including leap months and short lunar years.
- Solar terms use an approximation of apparent solar longitude, resolved to a civil day in China. They are not exact astronomical timestamps.
- The bundled `Sources/Typeflux/Resources/Holidays/cn.json` includes the official **2026** schedule. Years absent from that file use weekends for interval calculations, with an explicit notice; no holiday or makeup-workday dates are inferred.
- To add a year, copy the officially published holiday ranges and workdays into the JSON and add tests for holiday boundaries and adjusted working weekends. Updates currently ship with the app.
- The 2027 Spring Festival is **February 6**, correcting February 7 in the mockup; New Year's Eve is February 5.

Sources: [2026 State Council holiday notice](https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html), [2026 Hong Kong Observatory calendar](https://www.hko.gov.hk/en/gts/time/calendar/pdf/files/2026e.pdf), and [2027 Hong Kong Observatory calendar](https://www.hko.gov.hk/en/gts/time/calendar/pdf/files/2027e.pdf).

## Validation

The Calendar test suites cover parsing, civil-day arithmetic including daylight saving, lunar festivals, 2020–2030 Qingming dates, solstices, holiday/workday intervals, meeting URL validation, event ordering and cross-day occurrences, explicit permissions, stale-result cancellation, keyword migration and settings, and actual launcher keyboard routing. `CalendarLauncherVisualTests` renders the production launcher with injected events; set `TYPEFLUX_CALENDAR_SNAPSHOTS` to export its dark and light screenshots without using personal calendar data.

See the [validation report and screenshots](../validation/gul-364/README.md) for actual command results, coverage scope, and manual acceptance limits.
