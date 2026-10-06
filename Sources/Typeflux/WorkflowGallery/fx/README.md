# Exchange rates

- `fx 100 usd jpy` — convert 100 US dollars to yen. The first line is copied and sent as a notification.
- `fx 50 eur` — convert to the default currency (US dollars, or euros from US dollars).
- `rate` — one US dollar in each currency of the keyword's `to` option; `rate eur` uses euros as the base.

`fx` runs `main.py`, `rate` runs `table.py`; both import `rates.py`, which fetches rates from
open.er-api.com and caches them for an hour in the workflow's cache folder.
