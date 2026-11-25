"""Five-hour usage windows, the way Claude and ChatGPT plans meter agent use.

A window opens at the hour of the first request after a quiet period and lasts five hours; the next
request after it closes (or after five quiet hours) opens a new one. This mirrors ccusage's blocks, so
the numbers line up with what people already see there. The window boundaries are an estimate: the
provider's own reset time is not in the local logs.
"""

import json
import time
from collections import defaultdict
from decimal import Decimal

from .importers import TOKEN_FIELDS
from .pricing import Catalog
from .store import setting

WINDOW_MILLIS = 5 * 3600 * 1000
HOUR_MILLIS = 3600 * 1000
MINUTE_MILLIS = 60 * 1000


def windows(entries):
    """Group usage entries (sorted by time) into five-hour windows."""
    current = None
    for entry in entries:
        at = entry["at"]
        if current is None or at >= current["end"] or at - current["last_at"] >= WINDOW_MILLIS:
            if current is not None:
                yield current
            start = at - at % HOUR_MILLIS
            current = {"start": start, "end": start + WINDOW_MILLIS, "first_at": at, "last_at": at, "entries": []}
        current["last_at"] = at
        current["entries"].append(entry)
    if current is not None:
        yield current


def money(amount):
    return format(amount.quantize(Decimal("0.0001")), "f")


def describe(window, provider, catalog, now):
    tokens = dict.fromkeys(TOKEN_FIELDS, 0)
    models = defaultdict(int)
    api_value = Decimal(0)
    unpriced = 0
    for entry in window["entries"]:
        count = sum(entry[field] for field in TOKEN_FIELDS)
        for field in TOKEN_FIELDS:
            tokens[field] += entry[field]
        models[entry["model"] or "unknown"] += count
        quote = catalog.quote(entry)
        if quote is None:
            unpriced += count
        else:
            api_value += quote
    total = sum(tokens.values())
    active = window["start"] <= now < window["end"]
    result = {
        "provider": provider, "start": window["start"], "end": window["end"],
        "first_at": window["first_at"], "last_at": window["last_at"], "active": active,
        "requests": len(window["entries"]), "tokens": tokens, "total_tokens": total,
        "api_value_usd": money(api_value), "tokens_without_api_price": unpriced,
        "models": sorted(models, key=models.get, reverse=True),
    }
    if active:
        # Burn rate over the time the agent has actually been sending requests in this window,
        # projected to the end of the window as if that pace continued.
        elapsed = window["last_at"] - window["first_at"]
        remaining = window["end"] - now
        result["resets_in_minutes"] = remaining // MINUTE_MILLIS
        if elapsed >= MINUTE_MILLIS:
            per_minute = Decimal(total) / (Decimal(elapsed) / MINUTE_MILLIS)
            usd_per_minute = api_value / (Decimal(elapsed) / MINUTE_MILLIS)
            minutes_left = Decimal(remaining) / MINUTE_MILLIS
            result["burn_rate"] = {
                "tokens_per_minute": int(per_minute),
                "api_value_usd_per_hour": money(usd_per_minute * 60),
            }
            result["projection"] = {
                "total_tokens": int(total + per_minute * minutes_left),
                "api_value_usd": money(api_value + usd_per_minute * minutes_left),
            }
        else:
            result["burn_rate"] = None
            result["projection"] = None
    return result


def usage_blocks(conn, hours=24, active_only=False, now=None):
    now = int(time.time() * 1000) if now is None else now
    cutoff = now - hours * HOUR_MILLIS
    by_provider = defaultdict(list)
    providers = [row[0] for row in conn.execute(
        "SELECT DISTINCT provider FROM entries WHERE kind = 'usage' AND provider IS NOT NULL AND at > ? AND at <= ?",
        (cutoff - WINDOW_MILLIS, now))]
    for provider in providers:
        # Windows chain from one to the next, so start from the last request that followed five quiet hours:
        # the boundaries then match what a full history would give, however far back the chain goes.
        anchor = conn.execute(
            "SELECT max(at) FROM (SELECT at, at - lag(at) OVER (ORDER BY at) AS gap FROM entries "
            "WHERE kind = 'usage' AND provider = ? AND at <= ?) WHERE gap IS NULL OR gap >= ?",
            (provider, cutoff, WINDOW_MILLIS)).fetchone()[0]
        rows = conn.execute(
            "SELECT * FROM entries WHERE kind = 'usage' AND provider = ? AND at >= ? AND at <= ? ORDER BY at",
            (provider, cutoff if anchor is None else anchor, now))
        by_provider[provider] = [dict(row) for row in rows]
    catalog = Catalog(conn)
    found = []
    for provider, entries in sorted(by_provider.items()):
        for window in windows(entries):
            if window["end"] <= cutoff:
                continue
            block = describe(window, provider, catalog, now)
            if block["active"] or not active_only:
                found.append(block)
    found.sort(key=lambda block: (block["start"], block["provider"]), reverse=True)
    return {"now": now, "window_hours": WINDOW_MILLIS // HOUR_MILLIS, "blocks": found,
            "plan_limits": plan_limits(conn, now)}


def plan_limits(conn, now):
    """The plan usage a tool reported itself (Codex logs its 5-hour and weekly windows). Unlike the
    estimated blocks above, these are the provider's own numbers, as of the last request."""
    found = []
    for provider in ("codex",):
        try:
            raw = json.loads(setting(conn, f"{provider}_rate_limits", "{}"))
        except ValueError:
            continue
        if not isinstance(raw, dict) or not raw:
            continue
        observed = raw.get("observed_at")
        windows = []
        for name in ("primary", "secondary"):
            window = raw.get(name)
            if not isinstance(window, dict) or not isinstance(window.get("used_percent"), (int, float)):
                continue
            resets = window.get("resets_at")
            if isinstance(resets, (int, float)):
                resets_at = int(resets * 1000) if resets < 10**11 else int(resets)
            elif isinstance(window.get("resets_in_seconds"), (int, float)) and isinstance(observed, int):
                resets_at = observed + int(window["resets_in_seconds"] * 1000)
            else:
                resets_at = None
            # Once the window has reset, the logged percentage no longer applies.
            reset = resets_at is not None and resets_at <= now
            windows.append({
                "name": name, "window_minutes": window.get("window_minutes"),
                "used_percent": 0 if reset else window["used_percent"], "resets_at": resets_at,
                "resets_in_minutes": None if resets_at is None or reset else (resets_at - now) // MINUTE_MILLIS,
                "reset_since_observed": reset,
            })
        if windows:
            credits = raw.get("credits") if isinstance(raw.get("credits"), dict) else None
            found.append({"provider": provider, "observed_at": observed, "plan_type": raw.get("plan_type"),
                          "windows": windows, "credits": credits})
    return found
