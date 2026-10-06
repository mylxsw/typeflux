#!/usr/bin/env python3
# rate [base] -> one unit of the base in each currency of the keyword's `to` option.
import json
import os
import sys

from rates import fetch_rates

base = (sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "usd").strip().upper()
targets = [code.strip().upper() for code in os.environ.get("TYPEFLUX_OPTION_TO", "usd,eur,jpy").split(",")]
try:
    rates = fetch_rates(base)
except Exception as error:  # noqa: BLE001 - shown in the launcher as the reason
    print(json.dumps({"error": str(error)}))
    sys.exit(1)

for code in targets:
    if code != base and code in rates:
        print(f"1 {base} = {rates[code]:,.4f} {code}")
