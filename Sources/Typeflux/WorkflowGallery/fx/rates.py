"""Exchange rates from open.er-api.com, cached for an hour in the workflow's cache folder."""
import json
import os
import re
import time
import urllib.request

API = "https://open.er-api.com/v6/latest/{base}"
CACHE_SECONDS = 3600


def fetch_rates(base):
    """Rates for one unit of `base`, keyed by upper-case currency code."""
    base = base.upper()
    cache_dir = os.environ.get("TYPEFLUX_CACHE_DIR") or os.path.join(os.getcwd(), ".cache")
    cache = os.path.join(cache_dir, f"rates-{base}.json")
    try:
        if time.time() - os.path.getmtime(cache) < CACHE_SECONDS:
            with open(cache, encoding="utf-8") as file:
                return json.load(file)
    except OSError:
        pass
    with urllib.request.urlopen(API.format(base=base), timeout=10) as response:
        data = json.load(response)
    if data.get("result") != "success":
        raise ValueError(f"Unknown currency: {base}")
    rates = data["rates"]
    os.makedirs(cache_dir, exist_ok=True)
    with open(cache, "w", encoding="utf-8") as file:
        json.dump(rates, file)
    return rates


def parse(words, default_target="usd"):
    """`100 usd jpy`, `100usd to jpy`, `50 eur` → (amount, source, target)."""
    text = " ".join(words).lower().replace(",", "")
    match = re.fullmatch(r"\s*([\d.]+)?\s*([a-z]{3})?\s*(?:to|in|=)?\s*([a-z]{3})?\s*", text)
    if not match:
        raise ValueError("Try: 100 usd jpy")
    amount = float(match.group(1) or 1)
    source = match.group(2) or "usd"
    target = match.group(3) or default_target
    if target == source:
        target = "eur" if source == "usd" else "usd"
    return amount, source.upper(), target.upper()
