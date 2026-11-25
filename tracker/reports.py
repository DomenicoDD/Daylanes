from collections import defaultdict
from decimal import Decimal

from . import billing, openrouter
from .importers import TOKEN_FIELDS
from .pricing import Catalog
from .store import day_range, entries_for, hours, money, round_units, setting, subscriptions


def scope(conn, start, end, period):
    first, last, since, until = day_range(conn, start, end, period)
    return (
        {"start": first, "end_exclusive": last, "timezone": setting(conn, "timezone", "UTC"),
         "currency": setting(conn, "currency", "EUR")},
        list(entries_for(conn, since, until)),
    )


def prices_for(conn):
    return {(row["provider"], row["model"]): dict(row) for row in conn.execute("SELECT * FROM model_rates")}


def token_cents(entry, price):
    return Decimal(sum(entry[field] * price[field] for field in TOKEN_FIELDS)) / 1000000


def usd(amount):
    return money(round_units(amount * 100))


def time_and_usage(entries, prices, catalog):
    human = 0
    activities = defaultdict(int)
    agents = {}
    expenses = 0
    estimated = Decimal(0)
    unpriced = 0
    api_value = Decimal(0)
    api_unpriced = 0
    api_priced = 0
    task_ids = set()
    for e in entries:
        if e["task"]:
            task_ids.add(e["task"])
        if e["kind"] == "human":
            human += e["millis"]
            activities[e["label"]] += e["millis"]
        elif e["kind"] == "expense":
            expenses += e["cents"]
        else:
            provider = e["provider"]
            agent = agents.setdefault(provider, {
                "tokens": dict.fromkeys(TOKEN_FIELDS, 0), "runtime_millis": 0,
                "runtime_kind": None, "models": {}, "api_estimates": defaultdict(Decimal),
            })
            if e["kind"] == "runtime":
                agent["runtime_millis"] += e["millis"]
                agent["runtime_kind"] = e["label"]
                continue
            model = e["model"] or "unknown"
            model_usage = agent["models"].setdefault(model, dict.fromkeys(TOKEN_FIELDS, 0))
            for field in TOKEN_FIELDS:
                model_usage[field] += e[field]
                agent["tokens"][field] += e[field]
            price = prices.get((provider, e["model"]))
            if price is not None:
                estimated += token_cents(e, price)
            else:
                unpriced += sum(e[field] for field in TOKEN_FIELDS)
            quote = catalog.quote(e)
            count = sum(e[field] for field in TOKEN_FIELDS)
            if quote is None:
                api_unpriced += count
            else:
                api_priced += count
                api_value += quote
                agent["api_estimates"][model] += quote
    for agent in agents.values():
        agent["runtime_hours"] = hours(agent.pop("runtime_millis")) if agent["runtime_kind"] else None
        estimates = agent.pop("api_estimates")
        agent["api_equivalent_usd"] = usd(sum(estimates.values(), Decimal(0))) if estimates else None
        agent["model_api_equivalent_usd"] = {model: usd(amount) for model, amount in estimates.items()}
    return {
        "human_hours": hours(human), "human_by_activity": {k: hours(v) for k, v in sorted(activities.items())},
        "agents": agents, "task_ids": sorted(task_ids),
        "provider_expenses": money(expenses), "estimated_token_value": money(round_units(estimated)),
        "tokens_without_price": unpriced,
        "api_equivalent_usd": usd(api_value) if api_priced else None,
        "tokens_without_api_price": api_unpriced,
    }


def report(conn, start=None, end=None, period="week", project=None, client=None, task=None):
    bounds, entries = scope(conn, start, end, period)
    entries = [e for e in entries if (project is None or e["project"] == project)
               and (client is None or e["client"] == client)
               and (task is None or (e["task"] or "").casefold() == task.casefold())]
    grouped = defaultdict(list)
    for entry in entries:
        grouped[entry["project"]].append(entry)
    prices = prices_for(conn)
    catalog = Catalog(conn)
    projects = []
    for name, rows in sorted(grouped.items(), key=lambda group: (group[0] is None, group[0] or "")):
        projects.append({
            "project": name, "client": rows[0]["client"], "kind": rows[0]["project_kind"],
            **time_and_usage(rows, prices, catalog),
        })
    account_scope = project is None and client is None and task is None
    return {
        **bounds, "totals": time_and_usage(entries, prices, catalog), "projects": projects,
        "api_prices_fetched_at": catalog.fetched_at,
        "billing": billing.summary(conn, entries, catalog),
        "subscriptions": subscriptions(conn) if account_scope else None,
        "openrouter_account": openrouter.summary(conn, bounds["start"], bounds["end_exclusive"]) if account_scope else None,
    }


def review(conn, start=None, end=None, period="week"):
    bounds, entries = scope(conn, start, end, period)
    rows = defaultdict(lambda: {"event_count": 0, "tokens": 0, "runtime_millis": 0, "sample_entry_id": None})
    for entry in entries:
        if entry["project"] is None:
            key = (entry["provider"], entry["folder"], entry["branch"])
            item = rows[key]
            item["event_count"] += 1
            item["tokens"] += sum(entry[f] for f in TOKEN_FIELDS)
            item["runtime_millis"] += entry["millis"]
            item["sample_entry_id"] = entry["id"]
    return {**bounds, "unassigned": [
        {"provider": provider, "folder": folder, "branch": branch, **value}
        for (provider, folder, branch), value in rows.items()
    ]}


def clean(value):
    return " ".join(str(value).split())


def render_report(report_data):
    currency = report_data["currency"]
    lines = [f"{report_data['start']} to {report_data['end_exclusive']} (exclusive, {report_data['timezone']})"]
    plans = report_data["subscriptions"]
    if plans and plans["plans"]:
        lines.append(f"Current subscriptions: {currency} {plans['monthly_total']} per month")
        lines.extend(f"  {clean(plan['name'])}: {currency} {plan['monthly']} per month" for plan in plans["plans"])
    account = report_data["openrouter_account"]
    if account and account["start"]:
        total = account["totals"]
        lines.append(f"OpenRouter account, {account['start']} to {account['end_exclusive']} (exclusive, UTC)")
        lines.append(f"  USD {total['spend_usd']} reported spend · {total['requests']:,} requests · {total['tokens']:,} tokens")
    elif account:
        lines.append("OpenRouter account activity is unavailable for these dates.")
    for project in [*report_data["projects"], dict(report_data["totals"], project="Total")]:
        name = clean(project["project"] or "Unassigned")
        if project.get("client"):
            name += " / " + clean(project["client"])
        lines.append(f"\n{name} — {project['human_hours']} human hours")
        activities = project["human_by_activity"]
        if activities:
            lines.append("  " + ", ".join(f"{name}: {amount} h" for name, amount in activities.items()))
        for provider, metrics in sorted(project["agents"].items()):
            tokens = sum(metrics["tokens"].values())
            runtime = (f"{metrics['runtime_hours']} h ({metrics['runtime_kind']})"
                       if metrics["runtime_hours"] is not None else "runtime unavailable")
            lines.append(f"  {provider}: {tokens:,} tokens · {runtime}")
        if project["provider_expenses"] != "0.00":
            lines.append(f"  Provider expenses: {currency} {project['provider_expenses']}")
        if project["estimated_token_value"] != "0.00":
            lines.append(f"  Estimate at manual rates: {currency} {project['estimated_token_value']}")
        if project["api_equivalent_usd"] is not None:
            lines.append(f"  API equivalent (OpenRouter base token rates): USD {project['api_equivalent_usd']}")
        if project["tokens_without_api_price"]:
            lines.append(f"  Tokens without an API estimate: {project['tokens_without_api_price']:,}")
        if project["task_ids"]:
            lines.append("  Tasks: " + ", ".join(project["task_ids"]))
    return "\n".join(lines)
