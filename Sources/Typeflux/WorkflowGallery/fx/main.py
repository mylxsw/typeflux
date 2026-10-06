#!/usr/bin/env python3
# fx: 100 usd jpy -> live exchange rate. The first line is copied and sent as a notification.
import json
import os
import sys

from rates import fetch_rates, parse

try:
    default = (os.environ.get("TYPEFLUX_OPTION_TO") or "usd").split(",")[0]
    amount, src, dst = parse(sys.argv[1:] or ["1", "usd"], default)
    rate = fetch_rates(src)[dst]
except KeyError as missing:
    print(json.dumps({"error": f"Unknown currency: {missing.args[0]}"}))
    sys.exit(1)
except Exception as error:  # noqa: BLE001 - shown in the launcher as the reason
    print(json.dumps({"error": str(error)}))
    sys.exit(1)

print(f"{amount:g} {src} = {amount * rate:,.2f} {dst}")
print(f"1 {src} = {rate:.3f} {dst}")
