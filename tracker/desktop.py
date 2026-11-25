"""Shared local operations for the macOS view and cost export."""

import csv
import io
import os
from collections import defaultdict
from datetime import datetime, timezone

from . import billing, github, openrouter, pricing, reports, store, toggl

METRICS = ["uncached_input_tokens", "cached_input_tokens", "cache_write_tokens", "output_tokens"]
EXPORT_FIELDS = [
    "date", "client", "project", "project_kind", "task", "type", "activity", "provider",
    "model", "hours", "runtime_method", *METRICS, "currency", "actual_expense",
    "estimated_token_cost", "reimbursable", "time_source", "tag", "github_repo", "github_pr",
    "openrouter_model", "api_equivalent_usd", "bill_rate", "bill_markup", "bill_amount",
]
INVOICE_ITEMS = {"you": "Your time", "agent_time": "Agent time", "agent_usage": "Agent usage"}


def imported_group(entry):
    return (entry["provider"], entry["folder"], entry["branch"], entry["project"], entry["task"])


def snapshot(conn, start=None, end=None, period="week"):
    bounds, entries = reports.scope(conn, start, end, period)
    groups = defaultdict(list)
    projects = defaultdict(list)
    for entry in entries:
        if entry["provider"]:
            groups[imported_group(entry)].append(entry)
        if entry["project"]:
            projects[entry["project"]].append(entry)

    prices = reports.prices_for(conn)
    catalog = pricing.Catalog(conn)
    activity = []
    local = {}  # folder -> (repo from its Git remote, checked-out commit); read once per folder

    def local_git(path):
        if path not in local:
            repo = next(iter(github.worktree_repos(path)), None) if os.path.isdir(path) else None
            local[path] = (repo, github.head_commit(path) if repo else None)
        return local[path]

    for (provider, folder, branch, project, task), rows in groups.items():
        repo, commit = local_git(folder) if folder else (None, None)
        sessions = {}
        if provider in ("codex", "claude"):
            for row in reversed(rows):
                if row["session"]:
                    sessions.setdefault(row["session"], row["at"])
        activity.append({
            "provider": provider, "folder": folder, "branch": branch, "project": project, "task": task,
            "sessions": [{"id": key, "last_at": at} for key, at in sessions.items()],
            "client": rows[-1]["client"], "folder_repo": repo, "head_commit": commit,
            "first_at": min(row["at"] for row in rows), "last_at": rows[-1]["at"],
            "ended_at": max(row["at"] + ((row["millis"] or 0) if row["kind"] == "runtime" else 0) for row in rows),
            "entry_count": len(rows), "summary": reports.time_and_usage(rows, prices, catalog),
            "pull_request": rows[-1].get("pull_request"), "github_repo": rows[-1].get("github_repo"),
        })
    activity.sort(key=lambda item: item["last_at"], reverse=True)
    known_models = conn.execute(
        "SELECT DISTINCT provider, model FROM entries WHERE kind = 'usage' AND model IS NOT NULL "
        "ORDER BY provider, model"
    )
    pull_requests = defaultdict(list)
    for row in conn.execute("SELECT project, number, title, state, url FROM github_prs ORDER BY project, number DESC"):
        pull_requests[row["project"]].append({field: row[field] for field in ("number", "title", "state", "url")})
    project_list = store.project_list(conn)
    for project in project_list:
        # Each mapped folder with the GitHub repository its Git remote points to (read from local config only).
        project["folder_sources"] = [{"path": path, "repo": next(iter(github.worktree_repos(path)), None)}
                                     for path in project["folders"]]
        if project.get("github_repo"):
            project["github_pull_requests"] = pull_requests[project["name"]]
    return {
        **bounds,
        "totals": reports.time_and_usage(entries, prices, catalog),
        "activity": activity,
        "clients": store.client_list(conn),
        "self_client": store.self_client(conn),
        "projects": project_list,
        "project_totals": {name: reports.time_and_usage(rows, prices, catalog) for name, rows in projects.items()},
        "ever_imported": bool(conn.execute("SELECT 1 FROM sources UNION ALL "
                                           "SELECT 1 FROM entries WHERE kind = 'usage' LIMIT 1").fetchone()),
        "subscriptions": store.subscriptions(conn),
        "billing": billing.summary(conn, entries, catalog),
        "billing_terms": billing.terms_listing(conn),
        "toggl_account": toggl.linked(conn),
        "appearance": store.appearance_list(conn),
        "openrouter_account": openrouter.summary(conn, bounds["start"], bounds["end_exclusive"]),
        "api_prices_fetched_at": catalog.fetched_at,
        "models": [
            {"provider": row["provider"], "model": row["model"],
             "prices": prices.get((row["provider"], row["model"])),
             "openrouter_model": catalog.model(row["provider"], row["model"])}
            for row in known_models
        ],
    }


def assign_group(conn, target, provider, folder, branch, project, task, start, end, save_folder=False):
    store.get_project(conn, target)
    conn.execute("BEGIN IMMEDIATE")
    _, entries = reports.scope(conn, start, end, "week")
    key = (provider, folder, branch, project, task)
    ids = [(target, entry["id"]) for entry in entries if imported_group(entry) == key]
    if not ids:
        raise ValueError("This activity changed since it was loaded. Reload and try again.")
    conn.executemany("UPDATE entries SET project = ? WHERE id = ?", ids)
    if save_folder and folder:
        store.map_folder(conn, target, folder)
    return {"assigned": len(ids)}


def spreadsheet_text(value):
    if value is None:
        return ""
    text = str(value)
    if text.lstrip().startswith(("=", "+", "-", "@")) or text.startswith(("\t", "\r", "\n")):
        return "'" + text
    return text


def export_csv(conn, start=None, end=None, period="week", project=None, client=None):
    bounds, entries = reports.scope(conn, start, end, period)
    prices = reports.prices_for(conn)
    catalog = pricing.Catalog(conn)
    tz = store.zone(bounds["timezone"])
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer)
    writer.writerow(EXPORT_FIELDS)
    for entry in entries:
        if (project is not None and entry["project"] != project) or (client is not None and entry["client"] != client):
            continue
        kind = entry["kind"]
        tokens = [entry[k] for k in reports.TOKEN_FIELDS] if kind == "usage" else [""] * 4
        price = prices.get((entry["provider"], entry["model"]))
        estimate = reports.token_cents(entry, price) if price is not None and kind == "usage" else None
        quote = catalog.quote(entry) if kind == "usage" else None
        local = datetime.fromtimestamp(entry["at"] / 1000, timezone.utc).astimezone(tz)
        writer.writerow([
            local.date().isoformat(),
            *(spreadsheet_text(entry[field]) for field in ("client", "project", "project_kind", "task")),
            kind, spreadsheet_text(entry["label"] if kind != "runtime" else None),
            entry["provider"] or "", spreadsheet_text(entry["model"]),
            store.hours(entry["millis"]) if kind in ("human", "runtime") else "",
            entry["label"] if kind == "runtime" else "",
            *tokens, bounds["currency"],
            store.money(entry["cents"]) if kind == "expense" else "",
            format(estimate / 100, ".6f") if estimate is not None else "",
            ("yes" if entry["reimbursable"] else "no") if kind == "expense" else "",
            entry.get("time_source", "manual") if kind == "human" else "",
            spreadsheet_text(entry.get("tag")),
            spreadsheet_text(entry.get("github_repo")), entry.get("github_pr"),
            catalog.model(entry["provider"], entry["model"]) if quote is not None else "",
            format(quote, ".8f") if quote is not None else "",
            "", "", "",
        ])
    # Invoice lines follow the raw rows, one per billed item, dated at the start of the period.
    chosen = [e for e in entries if (project is None or e["project"] == project)
              and (client is None or e["client"] == client)]
    invoice = billing.summary(conn, chosen, catalog)
    blank = dict.fromkeys(EXPORT_FIELDS, "")
    for item in invoice["clients"]:
        # Only priced lines: a project without rates has nothing to invoice yet.
        lines = [(row["project"], line) for row in item["projects"] for line in row["lines"] if line["amount"]]
        if item["cap_reduction"]:
            lines.append((None, {"item": "cap", "amount": "-" + item["cap_reduction"]}))
        for name, line in lines:
            row = blank | {
                "date": bounds["start"], "client": spreadsheet_text(item["client"]),
                "project": spreadsheet_text(name), "type": "invoice",
                "activity": INVOICE_ITEMS.get(line["item"], "Monthly cap on agents"),
                "hours": line.get("hours") or "", "currency": bounds["currency"],
                "api_equivalent_usd": line.get("api_usd") or "", "bill_rate": line.get("rate") or "",
                "bill_markup": line.get("markup") or "", "bill_amount": line.get("amount") or "",
            }
            writer.writerow([row[field] for field in EXPORT_FIELDS])
    return buffer.getvalue()
