"""Report rows: the line items behind an invoice, each with an amount that adds up to the summary.

A row is one of your work sessions (your records of one project, task and local day, merged
when they are close together), one agent thread on one local day, or one expense. Time and
usage amounts are whole cents: per project and billed item, the rounded line of
``billing.summary`` is shared out over the rows in proportion to what each row contributed
(largest remainder), so any grouping of rows sums to the invoice to the cent. The monthly cap
stays a separate adjustment per client, and expenses are listed but not part of the invoice.
"""

from collections import Counter, defaultdict
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal
from pathlib import PurePath

from . import billing, reports, store
from .importers import TOKEN_FIELDS
from .pricing import Catalog

# The --activity choices that `tracker time` stores as a manual record's label.
ACTIVITY_CODES = frozenset(("prompting", "reviewing", "other"))
# Branch names that say nothing about the work: not a description.
GENERIC_BRANCHES = frozenset(("head", "main", "master", "develop", "dev", "trunk"))
ITEMS = (("you", "you", "time_amount"), ("agent_time", "agent", "time_amount"),
         ("agent_usage", "agent", "usage_amount"))


def local_day(at, tz):
    return datetime.fromtimestamp(at / 1000, timezone.utc).astimezone(tz).date()


def pieces(start, end, tz):
    """Split a span at local midnight into (day, start, end) pieces."""
    day = local_day(start, tz)
    while True:
        midnight = int(datetime.combine(day + timedelta(days=1), time.min, tz).timestamp() * 1000)
        if end <= midnight:
            yield day, start, end
            return
        yield day, start, midnight
        day, start = day + timedelta(days=1), midnight


def by_month(spans):
    """Billed length of tagged (start, end, month) spans: billing unions each month separately."""
    months = defaultdict(list)
    for start, end, month in spans:
        months[month].append((start, end))
    return sum(billing.length(billing.union(items)) for items in months.values())


def billable(entry):
    return entry["project_kind"] == "billable" and bool(entry["project"])


def base(entry, who, day, terms):
    values = billing.effective(terms, entry["client"], entry["project"]) if billable(entry) else None
    return {
        "id": None, "who": who, "date": day.isoformat(), "started_at": None, "ended_at": None,
        "client": entry["client"], "project": entry["project"], "project_kind": entry["project_kind"],
        "task": entry["task"] or None, "tags": [], "description": "", "provider": None, "models": [],
        "thread": None, "millis": 0, "billed_millis": 0, "tokens": dict.fromkeys(TOKEN_FIELDS, 0),
        "api_usd": None, "tokens_without_api_price": 0, "agent_mode": None, "rate": None,
        "time_amount": None, "usage_amount": None, "amount": None, "reimbursable": False,
    }, values


def human_rows(entries, tz, terms):
    """Your sessions, with each project's overlapping time billed once (to the earliest session)."""
    groups = defaultdict(list)
    for entry in entries:
        month = billing.month_of(entry["at"], tz)
        for day, start, end in pieces(entry["at"], entry["at"] + entry["millis"], tz):
            groups[(entry["project"], entry["task"] or None, day)].append((start, end, month, entry))
    sessions = []
    for (_, _, day), items in groups.items():
        merged, reach = [], None
        for piece in sorted(items, key=lambda item: (item[0], item[1], item[3]["id"])):
            if merged and piece[0] - reach <= billing.HUMAN_SPAN_GAP:
                merged[-1].append(piece)
                reach = max(reach, piece[1])
            else:
                merged.append([piece])
                reach = piece[1]
        sessions += [(day, parts) for parts in merged]
    rows = []
    covered = defaultdict(lambda: defaultdict(list))  # project -> month -> spans already billed
    for day, parts in sorted(sessions, key=lambda session: (session[1][0][0], session[1][0][3]["id"])):
        first = parts[0][3]
        row, values = base(first, "you", day, terms)
        seen = covered[first["project"]]
        billed = 0
        for month in {part[2] for part in parts}:
            before = billing.length(billing.union(seen[month]))
            spans = billing.union([*seen[month], *((s, e) for s, e, m, _ in parts if m == month)])
            seen[month] = [tuple(span) for span in spans]
            billed += billing.length(seen[month]) - before
        manual = [part[3] for part in parts if part[3].get("time_source") is None]
        # A manual record's label is its activity code (prompting, reviewing, other): not a description for a client.
        labels = list(dict.fromkeys(entry["label"] for entry in manual
                                    if entry["label"] and entry["label"] not in ACTIVITY_CODES))
        tags = sorted({part[3].get("tag") for part in parts if part[3].get("tag")})
        apps = Counter()
        for start, end, _, entry in parts:
            if entry.get("time_source") is not None and entry["label"]:
                apps[entry["label"]] += end - start
        top = sorted(apps.items(), key=lambda pair: (-pair[1], pair[0]))[:3]
        row.update(
            id=f"you:{row['date']}:{first['id']}", started_at=parts[0][0], ended_at=max(part[1] for part in parts),
            tags=tags, millis=billing.length(billing.union([(s, e) for s, e, _, _ in parts])), billed_millis=billed,
            description=", ".join(labels) or row["task"] or ", ".join(tags) or ", ".join(name for name, _ in top),
        )
        if values and values["human_cents"] is not None:
            row["rate"] = store.money(values["human_cents"])
        rows.append((row, {"you": Decimal(billed)}))
    return rows


def agent_description(task, branch, folder, project):
    """The task, else a branch that names the work, else (only without a project) the folder's name."""
    if task:
        return task
    if branch and branch.strip().lower() not in GENERIC_BRANCHES:
        return branch
    if not project and folder:
        return PurePath(folder).name
    return ""


def agent_rows(entries, tz, terms, catalog):
    """One row per project, agent thread and local day: running time and the tokens it used."""
    groups = defaultdict(lambda: {"entries": [], "spans": [], "stamps": []})
    for entry in entries:
        key = billing.thread_key(entry)
        if entry["kind"] == "runtime":
            month = billing.month_of(entry["at"], tz)
            for day, start, end in pieces(entry["at"], entry["at"] + entry["millis"], tz):
                group = groups[(entry["project"], key, day)]
                group["entries"].append(entry)
                group["spans"].append((start, end, month))
        else:
            group = groups[(entry["project"], key, local_day(entry["at"], tz))]
            group["entries"].append(entry)
            group["stamps"].append(entry["at"])
    rows = []
    for (_, (provider, thread), day), group in groups.items():
        items = group["entries"]
        row, values = base(items[0], "agent", day, terms)
        spans = [(start, end) for start, end, _ in group["spans"]]
        priced, usage_usd, models = Decimal(0), Decimal(0), set()
        quoted = False
        for entry in items:
            if entry["kind"] == "runtime":
                continue
            if entry["model"]:
                models.add(entry["model"])
            for field in TOKEN_FIELDS:
                row["tokens"][field] += entry[field] or 0
            quote = catalog.quote(entry)
            if quote is None:
                row["tokens_without_api_price"] += sum(entry[field] or 0 for field in TOKEN_FIELDS)
            else:
                quoted = True
                priced += quote
                if entry["kind"] == "usage":  # billing prices usage records only
                    usage_usd += quote
        tasks = Counter(entry["task"] for entry in items if entry["task"])
        branch = next((entry["branch"] for entry in items
                       if entry["branch"] and entry["branch"].strip().lower() not in GENERIC_BRANCHES), None)
        folder = next((entry["folder"] for entry in items if entry["folder"]), None)
        task = tasks.most_common(1)[0][0] if tasks else None
        bounds = spans or [(stamp, stamp) for stamp in group["stamps"]]
        billed = by_month(group["spans"])
        row.update(
            id=f"agent:{row['date']}:{min(items, key=lambda e: (e['at'], e['id']))['id']}",
            started_at=min(start for start, _ in bounds), ended_at=max(end for _, end in bounds),
            task=task, description=agent_description(task, branch, folder, row["project"]),
            provider=provider, models=sorted(models), thread=str(thread),
            millis=billing.length(billing.union(spans)), billed_millis=billed,
            api_usd=format(priced.quantize(Decimal("0.000001")), "f") if quoted else None,
        )
        if values:
            row["agent_mode"] = values["agent_mode"]
            if values["agent_mode"] in ("time", "hybrid") and values["agent_cents"] is not None:
                row["rate"] = store.money(values["agent_cents"])
        rows.append((row, {"agent_time": Decimal(billed), "agent_usage": usage_usd}))
    return rows


def expense_row(entry, tz, terms):
    row, _ = base(entry, "expense", local_day(entry["at"], tz), terms)
    row.update(id=f"expense:{entry['id']}", started_at=entry["at"], ended_at=entry["at"],
               description=entry["label"] or "", provider=entry["provider"],
               amount=store.money(entry["cents"] or 0), reimbursable=bool(entry["reimbursable"]))
    return row


def share(target, weighted):
    """Split ``target`` cents over (row, weight) pairs by largest remainder, ties by row id."""
    total = sum(weight for _, weight in weighted)
    if not total:  # nothing to weigh by: the first row carries the line
        weighted = [(row, Decimal(index == 0)) for index, (row, _) in enumerate(weighted)]
        total = Decimal(1)
    exact = [(row, target * weight / total) for row, weight in weighted]
    parts = [int(amount) for _, amount in exact]
    order = sorted(range(len(exact)), key=lambda index: (int(exact[index][1]) - exact[index][1], exact[index][0]["id"]))
    for index in order[:target - sum(parts)]:
        parts[index] += 1
    return [(row, cents) for (row, _), cents in zip(exact, parts)]


def build(conn, start=None, end=None, period="week", client=None, projects=None):
    """Report rows for a period, limited to a client and projects, reconciled with billing.summary."""
    bounds, entries = reports.scope(conn, start, end, period)
    entries = [e for e in entries if (client is None or e["client"] == client)
               and (not projects or e["project"] in projects)]
    tz = store.zone(bounds["timezone"])
    catalog = Catalog(conn)
    terms = billing.stored_terms(conn)
    summary = billing.summary(conn, entries, catalog)
    rows = human_rows([e for e in entries if e["kind"] == "human"], tz, terms)
    rows += agent_rows([e for e in entries if e["kind"] not in ("human", "expense") and e["provider"]],
                       tz, terms, catalog)
    lines = {(item["client"], project["project"], line["item"]): line["amount"]
             for item in summary["clients"] for project in item["projects"] for line in project["lines"]}
    candidates = defaultdict(list)
    for row, weights in rows:
        if row["project_kind"] == "billable" and row["project"]:
            for item, who, _ in ITEMS:
                if row["who"] == who:
                    candidates[(row["client"], row["project"], item)].append((row, weights[item]))
    fields = {item: field for item, _, field in ITEMS}
    for (owner, project, item), weighted in candidates.items():
        amount = lines.get((owner, project, item))
        if amount is None:
            continue
        target = store.round_units(Decimal(amount) * 100)
        chosen = [pair for pair in weighted if pair[1] > 0] or (weighted if target else [])
        for row, cents in share(target, chosen):
            row[fields[item]] = cents
    result = []
    for row, _ in rows:
        parts = [row[key] for key in ("time_amount", "usage_amount") if row[key] is not None]
        if parts:
            row["amount"] = store.money(sum(parts))
        for key in ("time_amount", "usage_amount"):
            if row[key] is not None:
                row[key] = store.money(row[key])
        result.append(row)
    result += [expense_row(e, tz, terms) for e in entries if e["kind"] == "expense"]
    result.sort(key=lambda row: (row["date"], row["started_at"] or 0, row["who"], row["project"] or "", row["id"]))
    adjustments = [{"client": item["client"], "kind": "monthly_cap", "monthly_cap": item["monthly_cap"],
                    "amount": "-" + item["cap_reduction"]} for item in summary["clients"] if item["cap_reduction"]]
    return {
        **bounds, "usd_exchange_rate": summary["usd_exchange_rate"],
        "needs_exchange_rate": summary["needs_exchange_rate"], "missing_human_rate": summary["missing_human_rate"],
        "client": client, "projects": list(projects) if projects else None,
        "rows": result, "adjustments": adjustments, "billing": summary,
    }
