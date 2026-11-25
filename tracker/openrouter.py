"""Account activity from OpenRouter's completed UTC days."""

import json
import os
import re
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from http.client import HTTPException
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .store import money, round_units, set_setting, setting

URL = "https://openrouter.ai/api/v1/activity"
CACHE_KEY = "openrouter_account_activity"
MAX_RESPONSE = 8 * 1024 * 1024


def endpoint(url):
    """TRACKER_HTTP_ROOT (like http://127.0.0.1:8000) replaces the scheme and host, so the parity check
    can serve both engines the same responses offline."""
    root = os.environ.get("TRACKER_HTTP_ROOT", "")
    if not root:
        return url
    rest = url.split("://", 1)[-1]
    return root.rstrip("/") + (rest[rest.index("/"):] if "/" in rest else "")


def now():
    """The current UTC time; TRACKER_NOW (epoch milliseconds) pins it for the parity check."""
    pinned = os.environ.get("TRACKER_NOW", "")
    if pinned.isdigit():
        return datetime.fromtimestamp(int(pinned) / 1000, timezone.utc)
    return datetime.now(timezone.utc)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_activity(key):
    key = key.strip()
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,512}", key):
        raise ValueError("Enter an OpenRouter management key")
    request = Request(endpoint(URL), headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
    try:
        with build_opener(NoRedirect()).open(request, timeout=8) as response:
            body = response.read(MAX_RESPONSE + 1)
    except HTTPError as error:
        error.close()
        if error.code in (401, 403):
            raise ValueError("OpenRouter denied access. Use a valid management key with activity access.") from None
        raise ValueError(f"OpenRouter activity request failed (HTTP {error.code}).") from None
    except (OSError, HTTPException):
        raise ValueError("Could not reach OpenRouter to refresh account activity.") from None
    if len(body) > MAX_RESPONSE:
        raise ValueError("OpenRouter activity response exceeded the size limit.")
    try:
        rows = json.loads(body, parse_float=Decimal)["data"]
        if isinstance(rows, list):
            return rows
    except (ValueError, KeyError, TypeError):
        pass
    raise ValueError("OpenRouter returned an unreadable activity response.")


def add(total, row):
    total["requests"] += row["requests"]
    total["tokens"] += row["tokens"]
    total["spend_usd"] += Decimal(row["spend_usd"])


def totals():
    return {"requests": 0, "tokens": 0, "spend_usd": Decimal(0)}


def activity_day(raw):
    if not isinstance(raw, str) or len(raw) > 40 or not raw.isascii() or not raw.isprintable():
        raise ValueError
    if len(raw) == 10:
        return date.fromisoformat(raw)
    stamp = datetime.fromisoformat(raw[:-1] + "+00:00" if raw.endswith("Z") else raw)
    return (stamp if stamp.tzinfo is None else stamp.astimezone(timezone.utc)).date()


def activity_amount(raw):
    if type(raw) not in (str, int, Decimal) or len(str(raw).encode()) > 128:
        raise ValueError
    value = Decimal(str(raw))
    if not value.is_finite() or not -128 <= value.as_tuple().exponent <= 128 or not 0 <= value <= 10**12:
        raise ValueError
    return value


def activity_count(raw):
    value = activity_amount(raw)
    integer = int(value)
    if value != integer:
        raise ValueError
    return integer


def refresh(conn, key):
    fetched = now()
    end = fetched.date()
    start = end - timedelta(days=30)
    groups = defaultdict(totals)
    for index, row in enumerate(fetch_activity(key), 1):
        field = "date"
        try:
            day = activity_day(row["date"])
            if not start <= day < end:
                continue
            counters = []
            for field in ("requests", "prompt_tokens", "completion_tokens"):
                counters.append(activity_count(row[field]))
            requests, prompt, output = counters
            field = "usage"
            spend = activity_amount(row[field])
        except (KeyError, ValueError, TypeError, InvalidOperation, OverflowError):
            raise ValueError(f"OpenRouter returned an invalid activity row (row {index}, {field}).") from None
        model = "Unknown model"
        for field in ("model", "model_permaslug"):
            label = row.get(field)
            if isinstance(label, str) and 0 < len(label.strip()) <= 256 and "\x00" not in label:
                model = label.strip()
                break
        # Completion already includes reasoning and prompt already includes cache hits.
        add(groups[(day.isoformat(), model)], {"requests": requests, "tokens": prompt + output, "spend_usd": spend})
    records = [{"day": day, "model": model, **value, "spend_usd": str(value["spend_usd"])}
               for (day, model), value in groups.items()]
    cache = {"start": start.isoformat(), "end_exclusive": end.isoformat(),
             "fetched_at": int(fetched.timestamp()), "records": records}
    set_setting(conn, CACHE_KEY, json.dumps(cache))
    return {"days": 30, "groups": len(records)}


def clear(conn):
    conn.execute("DELETE FROM settings WHERE key = ?", (CACHE_KEY,))


def summary(conn, start, end):
    saved = setting(conn, CACHE_KEY, None)
    if saved is None:
        return None
    cache = json.loads(saved)
    first, until = max(cache["start"], start), min(cache["end_exclusive"], end)
    total, models = totals(), defaultdict(totals)
    for row in cache["records"]:
        if first <= row["day"] < until:
            add(total, row)
            add(models[row["model"]], row)

    def display(value):
        return {**value, "spend_usd": money(round_units(value["spend_usd"] * 100))}

    return {
        "fetched_at": cache["fetched_at"],
        "start": first if first < until else None,
        "end_exclusive": until if first < until else None,
        "totals": display(total),
        "models": [{"model": model, **display(value)} for model, value in
                   sorted(models.items(), key=lambda item: (-item[1]["spend_usd"], item[0]))],
    }
