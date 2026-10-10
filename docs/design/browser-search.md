# Browser tab and bookmark search

The launcher supports Safari, Google Chrome, Dia, Arc and Microsoft Edge.

- `tab` lists open tabs and filters their titles, URLs and profiles/spaces. Return focuses the existing tab; it does not open a duplicate. Command-C copies its URL.
- `bmk` lists saved bookmarks, including nested folders and Chromium profiles. Return opens the link with the source browser, the system default, or a browser selected in settings. Command-C copies its URL.
- Settings → Launcher → Search → Browsers has independent feature, direct-search and browser toggles for each source. Keywords can be renamed or disabled on the Keywords page.
- Direct search includes up to five matching tabs and five matching bookmarks. Existing application/file ranking keeps its Return behavior; browser results are selected with the arrows, mouse or number shortcuts.

## Sources and permissions

Tabs use the installed browser's scripting dictionary through JXA. Safari uses `currentTab`; Chrome/Edge use `activeTabIndex`; Dia uses `focus`; Arc uses `select`. Window/tab identity and the captured URL are checked before switching. Safari lacks stable tab IDs, so a changed tab index/URL requires refreshing. Windows and tabs across Dia profiles and Arc spaces are included, with ungrouped window tabs as a fallback.

Explicit `tab` searches may request macOS Automation permission. Background/direct queries first check the existing grant without prompting. Neither kind of search launches a closed browser. Listing and focusing do not require permission to execute JavaScript in web pages.

Bookmarks are read locally: Safari's `Library/Safari/Bookmarks.plist`; Chrome, Dia and Edge's profile `Bookmarks` files; Arc's `StorableSidebar.json`. Safari may require Full Disk Access. Missing files are normal; permission errors and corrupt files appear as separate rows, alongside any available results. Arc favorites and pinned trees count as bookmarks; daily/unpinned tabs and Safari Reading List do not. Bookmarklets are excluded.

Browser data remains in memory on this Mac. Tab snapshots expire after two seconds; bookmark snapshots expire after five seconds. Requests coalesce, sources run independently, and old-query results cannot execute while a new query is pending. Lists periodically refresh, and Command-R requests another run.

## Validation

`AskBrowserSearchTests` covers native file formats, nested folders, profiles/spaces, unsafe URLs, missing/corrupt files, permission gates, cache coalescing, stale tabs, keyword conflicts, direct-search cancellation and native settings/results rendering. The native script engine compiles all five listing and focus adapters without operating a browser.

Set `TYPEFLUX_BROWSER_SCRIPT_OUTPUT` to export the adapters for integration checks and `TYPEFLUX_BROWSER_VISUAL_OUTPUT` to save the rendered settings and results images when running this suite.

Adapter references: installed Safari/Chrome/Dia scripting dictionaries; [Dia's AppleScript release notes](https://www.diabrowser.com/changelog/mac/1-7-0); [Arc extension source](https://github.com/raycast/extensions/blob/main/extensions/arc/src/arc.ts); [Arc sidebar format reference](https://gist.github.com/wargoblin/91add48695b2a6bf8b9cc91145844815).
