# Local IP

- `ip` — lists this Mac's network addresses (IPv4 and IPv6, by network port) and its local host name.
- `ip en0` or `ip 192.168` — only the addresses that match.

Return copies the chosen address; Option-Return types it into the app you came from.

Only this Mac is asked: the workflow does not look up your public address, so it never goes online.

The script prints an item list (`{"items": [...]}`) in the format of Alfred's Script Filter.
