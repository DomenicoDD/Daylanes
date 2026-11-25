"""Billing: what you charge a client for your time and for your agents' work.

Terms live on the client and a project can override any of them:

* ``human_cents``: your hourly rate.
* ``agent_mode``: how agents are billed. ``time`` bills agent hours at ``agent_cents`` per hour,
  ``usage`` bills the API-credit value (USD, OpenRouter rates) times ``usage_markup``, ``hybrid``
  bills both as separate lines, and ``none`` leaves agents off the invoice.
* ``monthly_cap_cents`` (client only): the most the agent lines can add up to in a calendar month.

Your time can overlap across projects (an hour of context switching between two projects bills
as two hours), but overlapping records inside one project count once. Agent time is the running
time of each thread, so two threads running in parallel bill twice the hours.
"""

from collections import defaultdict
from datetime import date, datetime, time, timezone
from decimal import Decimal, InvalidOperation

from . import store
from .importers import TOKEN_FIELDS
from .pricing import Catalog

MODES = ("none", "time", "usage", "hybrid")
FIELDS = ("human_cents", "agent_mode", "agent_cents", "usage_markup", "monthly_cap_cents")
# Your records closer together than this are drawn as one billing block (the hours stay exact).
HUMAN_SPAN_GAP = 10 * 60 * 1000
# Agent runs of one project closer together than this are drawn as one block, matching the agent columns.
AGENT_SPAN_GAP = 20 * 60 * 1000
LANE_CLEARANCE = 20 * 60 * 1000
HOUR = Decimal(3600000)


def decimal_value(value, label, maximum):
    try:
        amount = Decimal(str(value).strip())
        if not amount.is_finite() or not 0 < amount <= maximum:
            raise ValueError
        return amount
    except (InvalidOperation, ValueError):
        raise ValueError(f"{label} must be a number above 0 and at most {maximum}") from None


def blank(value):
    return value is None or not str(value).strip()


def save_terms(conn, scope, name, human_rate=None, agent_mode=None, agent_rate=None, markup=None, cap=None):
    """Replace the terms of a client or project. A blank value means unset (a project then uses its client's)."""
    if scope not in ("client", "project"):
        raise ValueError("Billing terms belong to a client or a project")
    name = store.required(name, "Name")
    if scope == "project":
        store.get_project(conn, name)
        if not blank(cap):
            raise ValueError("The monthly cap is set on the client")
    elif name not in store.client_list(conn):
        raise ValueError(f"Unknown client: {name}")
    if not blank(agent_mode) and agent_mode not in MODES:
        raise ValueError("Bill agents by none, time, usage, or hybrid")
    values = (
        None if blank(human_rate) else store.cents(human_rate),
        None if blank(agent_mode) else agent_mode,
        None if blank(agent_rate) else store.cents(agent_rate),
        None if blank(markup) else str(decimal_value(markup, "The usage markup", 100)),
        None if blank(cap) else store.cents(cap),
    )
    if all(value is None for value in values):
        conn.execute("DELETE FROM billing_terms WHERE scope = ? AND name = ?", (scope, name))
    else:
        conn.execute("INSERT OR REPLACE INTO billing_terms VALUES (?, ?, ?, ?, ?, ?, ?)", (scope, name, *values))


def set_exchange_rate(conn, value):
    if blank(value):
        conn.execute("DELETE FROM settings WHERE key = 'usd_exchange_rate'")
    else:
        store.set_setting(conn, "usd_exchange_rate", str(decimal_value(value, "The exchange rate", 1000)))


def exchange_rate(conn):
    """Ledger currency per US dollar, used to put API-credit value on an invoice."""
    if store.setting(conn, "currency", "EUR") == "USD":
        return Decimal(1)
    value = store.setting(conn, "usd_exchange_rate", None)
    return Decimal(value) if value else None


def stored_terms(conn):
    terms = {"client": {}, "project": {}}
    for row in conn.execute("SELECT * FROM billing_terms"):
        terms[row["scope"]][row["name"]] = {field: row[field] for field in FIELDS}
    return terms


def display_terms(values):
    """Terms as the app shows them: money as decimal strings, unset fields as null."""
    if values is None:
        return None
    return {
        "human_rate": store.money(values["human_cents"]) if values["human_cents"] is not None else None,
        "agent_mode": values["agent_mode"],
        "agent_rate": store.money(values["agent_cents"]) if values["agent_cents"] is not None else None,
        "usage_markup": values["usage_markup"],
        "monthly_cap": store.money(values["monthly_cap_cents"]) if values["monthly_cap_cents"] is not None else None,
    }


def terms_listing(conn):
    terms = stored_terms(conn)
    return {
        # Lists rather than objects keyed by name: the app decodes keys from snake case, which would alter names.
        "clients": [{"name": name, **display_terms(values)} for name, values in sorted(terms["client"].items())],
        "projects": [{"name": name, **display_terms(values)} for name, values in sorted(terms["project"].items())],
        "usd_exchange_rate": store.setting(conn, "usd_exchange_rate", None),
    }


def effective(terms, client, project):
    merged = dict.fromkeys(FIELDS)
    for values in (terms["client"].get(client), terms["project"].get(project)):
        for field, value in (values or {}).items():
            if value is not None:
                merged[field] = value
    merged["monthly_cap_cents"] = (terms["client"].get(client) or {}).get("monthly_cap_cents")
    merged["agent_mode"] = merged["agent_mode"] or "none"
    merged["usage_markup"] = Decimal(merged["usage_markup"] or 1)
    return merged


def union(spans):
    merged = []
    for start, end in sorted(spans):
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def length(spans):
    return sum(end - start for start, end in spans)


def thread_key(entry):
    return (entry["provider"], entry["session"] or entry["folder"] or entry["id"])


def month_of(at, tz):
    return datetime.fromtimestamp(at / 1000, timezone.utc).astimezone(tz).strftime("%Y-%m")


class Usage:
    """What one billable project used in one month: your spans, agent spans per thread, API value."""

    def __init__(self):
        self.human = []
        self.threads = defaultdict(list)
        self.api_usd = Decimal(0)
        self.unpriced_tokens = 0

    def human_millis(self):
        return length(union(self.human))

    def agent_millis(self):
        return sum(length(union(spans)) for spans in self.threads.values())


def collect(entries, catalog, tz):
    usage = defaultdict(Usage)
    for entry in entries:
        if entry["project_kind"] != "billable" or not entry["project"]:
            continue
        item = usage[(entry["client"], entry["project"], month_of(entry["at"], tz))]
        if entry["kind"] == "human":
            item.human.append((entry["at"], entry["at"] + entry["millis"]))
        elif entry["kind"] == "runtime" and entry["provider"]:
            item.threads[thread_key(entry)].append((entry["at"], entry["at"] + entry["millis"]))
        elif entry["kind"] == "usage" and entry["provider"]:
            quote = catalog.quote(entry)
            if quote is None:
                item.unpriced_tokens += sum(entry[field] or 0 for field in TOKEN_FIELDS)
            else:
                item.api_usd += quote
    return usage


def charges(item, terms, fx):
    """Uncapped amounts in cents (Decimal) for one project-month: you, agent time, agent usage."""
    you = Decimal(item.human_millis()) / HOUR * terms["human_cents"] if terms["human_cents"] is not None else None
    mode = terms["agent_mode"]
    agent_time = agent_usage = None
    if mode in ("time", "hybrid") and terms["agent_cents"] is not None:
        agent_time = Decimal(item.agent_millis()) / HOUR * terms["agent_cents"]
    if mode in ("usage", "hybrid") and fx is not None:
        agent_usage = item.api_usd * terms["usage_markup"] * fx * 100
    return you, agent_time, agent_usage


def month_bounds(month, tz):
    year, number = (int(part) for part in month.split("-"))
    first = date(year, number, 1)
    last = date(year + number // 12, number % 12 + 1, 1)
    return [int(datetime.combine(day, time.min, tz).timestamp() * 1000) for day in (first, last)]


def cap_factors(conn, usage, terms, fx, catalog, tz):
    """Per (client, month), the share of agent charges left after that client's monthly cap.

    The cap applies to the whole calendar month, so a week inside a capped month bills its
    proportional share of the cap rather than running into it on the last days.
    """
    factors = {}
    for client, month in {(client, month) for client, _, month in usage}:
        cap = (terms["client"].get(client) or {}).get("monthly_cap_cents")
        if cap is None:
            continue
        start, end = month_bounds(month, tz)
        month_usage = collect(store.entries_for(conn, start, end), catalog, tz)
        total = Decimal(0)
        for (other, project, _), item in month_usage.items():
            if other == client:
                _, agent_time, agent_usage = charges(item, effective(terms, client, project), fx)
                total += (agent_time or 0) + (agent_usage or 0)
        factors[(client, month)] = min(Decimal(1), Decimal(cap) / total) if total else Decimal(1)
    return factors


def cents_text(amount):
    return store.money(store.round_units(amount))


def summary(conn, entries, catalog=None):
    """Invoice lines per client and project for these entries (already limited to a period)."""
    catalog = catalog or Catalog(conn)
    tz = store.zone(store.setting(conn, "timezone", "UTC"))
    fx = exchange_rate(conn)
    terms = stored_terms(conn)
    usage = collect(entries, catalog, tz)
    factors = cap_factors(conn, usage, terms, fx, catalog, tz)

    projects = defaultdict(lambda: {"human_millis": 0, "agent_millis": 0, "api_usd": Decimal(0), "unpriced": 0,
                                    "you": None, "agent_time": None, "agent_usage": None, "capped": Decimal(0)})
    for (client, project, month), item in usage.items():
        values = effective(terms, client, project)
        row = projects[(client, project)]
        row["terms"] = values
        row["human_millis"] += item.human_millis()
        row["agent_millis"] += item.agent_millis()
        row["api_usd"] += item.api_usd
        row["unpriced"] += item.unpriced_tokens
        you, agent_time, agent_usage = charges(item, values, fx)
        factor = factors.get((client, month), Decimal(1))
        for key, amount in (("you", you), ("agent_time", agent_time), ("agent_usage", agent_usage)):
            if amount is not None:
                row[key] = (row[key] or Decimal(0)) + amount
        row["capped"] += ((agent_time or 0) + (agent_usage or 0)) * (1 - factor)

    clients = {}
    missing_rate = False
    for (client, project), row in sorted(projects.items(), key=lambda pair: (pair[0][0] or "", pair[0][1])):
        values = row["terms"]
        lines = []
        if row["human_millis"]:
            if values["human_cents"] is None:
                missing_rate = True
            lines.append({"item": "you", "hours": store.hours(row["human_millis"]),
                          "rate": store.money(values["human_cents"]) if values["human_cents"] is not None else None,
                          "amount": cents_text(row["you"]) if row["you"] is not None else None})
        mode = values["agent_mode"]
        if mode in ("time", "hybrid") and row["agent_millis"]:
            lines.append({"item": "agent_time", "hours": store.hours(row["agent_millis"]),
                          "rate": store.money(values["agent_cents"]) if values["agent_cents"] is not None else None,
                          "amount": cents_text(row["agent_time"]) if row["agent_time"] is not None else None})
        if mode in ("usage", "hybrid") and (row["api_usd"] or row["unpriced"]):
            lines.append({"item": "agent_usage", "api_usd": format(row["api_usd"].quantize(Decimal("0.01")), "f"),
                          "markup": format(values["usage_markup"].normalize(), "f"),
                          "tokens_without_api_price": row["unpriced"],
                          "amount": cents_text(row["agent_usage"]) if row["agent_usage"] is not None else None})
        if not lines:
            continue
        total = sum(Decimal(line["amount"]) for line in lines if line["amount"] is not None)
        entry = clients.setdefault(client, {"client": client, "projects": [], "cap_reduction": Decimal(0),
                                            "monthly_cap": None})
        cap = (terms["client"].get(client) or {}).get("monthly_cap_cents")
        entry["monthly_cap"] = store.money(cap) if cap is not None else None
        entry["cap_reduction"] += row["capped"]
        entry["projects"].append({"project": project, "agent_mode": mode, "lines": lines,
                                  "subtotal": format(total, ".2f")})

    result = []
    grand = Decimal(0)
    for client in clients.values():
        subtotal = sum(Decimal(project["subtotal"]) for project in client["projects"])
        reduction = Decimal(cents_text(client.pop("cap_reduction")))
        client["cap_reduction"] = format(reduction, ".2f") if reduction else None
        client["total"] = format(subtotal - reduction, ".2f")
        grand += subtotal - reduction
        result.append(client)
    return {
        "currency": store.setting(conn, "currency", "EUR"),
        "usd_exchange_rate": format(fx, "f") if fx is not None else None,
        "needs_exchange_rate": fx is None and any(line["item"] == "agent_usage"
                                                  for client in result for project in client["projects"]
                                                  for line in project["lines"]),
        "missing_human_rate": missing_rate,
        "clients": result,
        "total": format(grand, ".2f"),
    }


def pack(spans):
    """Give overlapping spans separate lanes, keeping some clearance because short blocks are drawn taller."""
    lanes = []
    for span in sorted(spans, key=lambda item: (item["started_at"], item["project"])):
        lane = next((index for index, end in enumerate(lanes) if span["started_at"] >= end + LANE_CLEARANCE), None)
        if lane is None:
            lane = len(lanes)
            lanes.append(0)
        lanes[lane] = span["ended_at"]
        span["lane"] = lane
    return spans


def day_spans(conn, entries):
    """Billing blocks for the day view: your billable time and agent time, per billable project."""
    terms = stored_terms(conn)
    human = defaultdict(list)
    threads = defaultdict(lambda: defaultdict(list))
    clients = {}
    for entry in entries:
        if entry["project_kind"] != "billable" or not entry["project"]:
            continue
        clients[entry["project"]] = entry["client"]
        if entry["kind"] == "human":
            human[entry["project"]].append((entry["at"], entry["at"] + entry["millis"]))
        elif entry["kind"] == "runtime" and entry["provider"] and entry["millis"]:
            threads[entry["project"]][thread_key(entry)].append((entry["at"], entry["at"] + entry["millis"]))

    def grouped(spans, gap):
        blocks = []
        for start, end in union(spans):
            if blocks and start - blocks[-1][1] <= gap:
                blocks[-1][1] = end
            else:
                blocks.append([start, end])
        return blocks

    def clip(spans, start, end):
        return [(max(a, start), min(b, end)) for a, b in spans if b > start and a < end]

    you = []
    for project, spans in human.items():
        exact = union(spans)
        rate = effective(terms, clients[project], project)["human_cents"]
        for start, end in grouped(spans, HUMAN_SPAN_GAP):
            millis = length(clip(exact, start, end))
            you.append({"project": project, "client": clients[project], "started_at": start, "ended_at": end,
                        "billed_millis": millis,
                        "amount": cents_text(Decimal(millis) / HOUR * rate) if rate is not None else None})
    ai = []
    for project, by_thread in threads.items():
        values = effective(terms, clients[project], project)
        if values["agent_mode"] == "none":
            continue
        busy = {key: union(spans) for key, spans in by_thread.items()}
        everything = [span for spans in busy.values() for span in spans]
        for start, end in grouped(everything, AGENT_SPAN_GAP):
            inside = {key: clip(spans, start, end) for key, spans in busy.items()}
            millis = sum(length(spans) for spans in inside.values())
            rate = values["agent_cents"] if values["agent_mode"] in ("time", "hybrid") else None
            ai.append({"project": project, "client": clients[project], "started_at": start, "ended_at": end,
                       "billed_millis": millis, "threads": sum(1 for spans in inside.values() if spans),
                       "agent_mode": values["agent_mode"],
                       "amount": cents_text(Decimal(millis) / HOUR * rate) if rate is not None else None})
    return {"you": pack(you), "ai": pack(ai)}
