import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from . import billing, blocks, desktop, focus, github, importers, openrouter, pricing, report_rows, reports, store, toggl


def parser():
    cli = argparse.ArgumentParser(prog="tracker", description="Local time and agent usage for client work.")
    cli.add_argument("--db", type=Path, help="SQLite database path (or set TRACKER_DB)")
    commands = cli.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init", help="Set reporting defaults")
    timezone_option = init.add_mutually_exclusive_group()
    timezone_option.add_argument("--timezone")
    timezone_option.add_argument("--default-timezone", help="Set a timezone only if the ledger has none")
    init.add_argument("--currency")

    projects = commands.add_parser("project", help="Create or classify projects and map folders")
    project_commands = projects.add_subparsers(dest="action", required=True)
    add = project_commands.add_parser("add", help="Create or update a project")
    add.add_argument("name")
    add.add_argument("--client")
    add.add_argument("--kind", choices=("billable", "internal", "personal"), required=True)
    add.add_argument("--folder")
    add.add_argument("--github", help="Associate a GitHub repository as owner/repo")
    add.add_argument("--new-only", action="store_true", help="Reject a project name that already exists")
    mapping = project_commands.add_parser("map", help="Map another folder or worktree to a project")
    mapping.add_argument("name")
    mapping.add_argument("folder")
    unmapping = project_commands.add_parser("unmap", help="Stop sending a folder's work to a project")
    unmapping.add_argument("name")
    unmapping.add_argument("folder")
    project_commands.add_parser("list")

    clients = commands.add_parser("client", help="Manage local clients")
    client_commands = clients.add_subparsers(dest="action", required=True)
    client_commands.add_parser("list")
    client_save = client_commands.add_parser("save")
    client_save.add_argument("name")
    client_save.add_argument("--previous")

    bill = commands.add_parser("billing", help="Set what you bill clients for your time and your agents")
    bill_commands = bill.add_subparsers(dest="action", required=True)
    bill_commands.add_parser("show", help="List billing terms")
    terms = bill_commands.add_parser("set", help="Replace the terms of a client or project (blank values are unset)")
    target = terms.add_mutually_exclusive_group(required=True)
    target.add_argument("--client")
    target.add_argument("--project")
    terms.add_argument("--human-rate", help="Your hourly rate in the ledger currency")
    terms.add_argument("--agent-mode", choices=("", *billing.MODES), help="How agents are billed")
    terms.add_argument("--agent-rate", help="Hourly rate for agent time")
    terms.add_argument("--markup", help="Multiplier on the API-credit value for usage billing")
    terms.add_argument("--cap", help="Monthly cap on agent charges for a client")
    fx = bill_commands.add_parser("exchange-rate", help="Ledger currency per US dollar for usage billing")
    fx.add_argument("rate", help="For example 0.92; blank to clear")
    invoice = bill_commands.add_parser("summary", help="Invoice lines for a period")
    invoice.add_argument("--period", choices=("week", "month"), default="month")
    invoice.add_argument("--start")
    invoice.add_argument("--end")

    look = commands.add_parser("appearance", help="Set a client's icon or a project's colour")
    who = look.add_mutually_exclusive_group(required=True)
    who.add_argument("--client")
    who.add_argument("--project")
    look.add_argument("--color", help="#RRGGBB, or blank for automatic")
    look.add_argument("--icon", help="PNG or JPEG file, or blank to remove")

    work = commands.add_parser("time", help="Log time you spent working")
    work.add_argument("project")
    work.add_argument("--minutes", required=True)
    work.add_argument("--activity", choices=("prompting", "reviewing", "other"), default="other")
    work.add_argument("--task")
    work.add_argument("--at", help="ISO timestamp or local date; defaults to now")

    expense = commands.add_parser("expense", help="Record an actual provider charge in the reporting currency")
    expense.add_argument("project")
    expense.add_argument("description")
    expense.add_argument("--amount", required=True)
    expense.add_argument("--reimburse", action="store_true", help="Mark the expense as reimbursable in exports")
    expense.add_argument("--task")
    expense.add_argument("--at", help="ISO timestamp or local date; defaults to now")

    prices = commands.add_parser("model-rate", help="Set estimated prices per million tokens")
    prices.add_argument("provider", type=importers.harness_id)
    prices.add_argument("model")
    prices.add_argument("--input", required=True, help="Price for uncached input")
    prices.add_argument("--cached", required=True, help="Price for cache reads")
    prices.add_argument("--cache-write", required=True, help="Price for cache writes")
    prices.add_argument("--output", required=True)

    catalog = commands.add_parser("refresh-prices", help="Cache public OpenRouter token prices in USD")
    catalog.add_argument("--if-stale", action="store_true", help="Skip a catalog fetched in the last 24 hours")

    activity = commands.add_parser("openrouter-sync", help="Read OpenRouter account activity with a management key")
    credential = activity.add_mutually_exclusive_group()
    credential.add_argument("--key-stdin", action="store_true", help="Read the key from stdin; default is OPENROUTER_MANAGEMENT_KEY")
    credential.add_argument("--clear", action="store_true", help="Clear locally cached OpenRouter account activity")

    toggl_cli = commands.add_parser("toggl", help="Read Toggl Track using an API token provided on stdin")
    toggl_commands = toggl_cli.add_subparsers(dest="action", required=True)
    toggl_commands.add_parser("projects", help="List available Toggl Track projects")
    toggl_link = toggl_commands.add_parser("link", help="Verify the token and remember the connected account")
    toggl_link.add_argument("--workspace", type=int)
    toggl_workspace = toggl_commands.add_parser("workspace", help="Choose the workspace to read (no token needed)")
    toggl_workspace.add_argument("id", type=int)
    toggl_commands.add_parser("unlink", help="Forget the connected account (the token lives in Keychain)")
    toggl_import = toggl_commands.add_parser("import", help="Import completed Toggl Track time into a local project")
    toggl_import.add_argument("--source", required=True, type=int)
    toggl_import.add_argument("--project", required=True)
    toggl_import.add_argument("--start", required=True)
    toggl_import.add_argument("--end", required=True)

    plans = commands.add_parser("subscription", help="Manage the current monthly plan fees in the ledger currency")
    plan_commands = plans.add_subparsers(dest="action", required=True)
    plan_set = plan_commands.add_parser("set")
    plan_set.add_argument("name")
    plan_set.add_argument("--monthly", required=True)
    plan_set.add_argument("--provider")
    plan_set.add_argument("--new-only", action="store_true")
    plan_remove = plan_commands.add_parser("remove")
    plan_remove.add_argument("name")
    plan_commands.add_parser("list")

    harness = commands.add_parser("import-harness", help="Import normalized usage JSONL from another harness (stdin)")
    harness.add_argument("name", type=importers.harness_id)

    sync = commands.add_parser("sync", help="Import local Codex, Claude Code and OpenCode history")
    sync.add_argument("--provider", choices=("all", *importers.PROVIDERS), default="all")
    sync.add_argument("--codex-dir")
    sync.add_argument("--claude-dir")
    sync.add_argument("--opencode-db", type=Path, help="Read this OpenCode SQLite database")
    sync.add_argument("--recent-days", type=int, help="Only scan recent transcript files or OpenCode messages")
    sync.add_argument("--rescan", action="store_true", help="Read unchanged transcript files again")

    windows = commands.add_parser("blocks", help="Agent usage in five-hour windows, with burn rate")
    windows.add_argument("--hours", type=int, default=24, help="How far back to list windows (default 24)")
    windows.add_argument("--active", action="store_true", help="Only the windows open now")

    remove = commands.add_parser("remove", help="Delete a manually logged time or expense entry")
    remove.add_argument("entry_id")

    assign = commands.add_parser("assign", help="Override the project of an imported entry")
    assign.add_argument("entry_id")
    action = assign.add_mutually_exclusive_group(required=True)
    action.add_argument("--project")
    action.add_argument("--use-folder", action="store_true", help="Clear the override and use folder mapping")

    for name, default, label in (
        ("report", "week", "Summarize your time, agent usage and expenses"),
        ("review", "week", "Find imported usage without a project"),
        ("snapshot", "week", "Read usage and project data for the desktop app"),
        ("export", "week", "Export time, usage, and costs as CSV"),
    ):
        command = commands.add_parser(name, help=label)
        command.add_argument("--period", choices=("week", "month"), default=default)
        command.add_argument("--start", help="Inclusive local date (YYYY-MM-DD)")
        command.add_argument("--end", help="Exclusive local date (YYYY-MM-DD)")
        if name == "report":
            command.add_argument("--json", action="store_true", dest="as_json")
            command.add_argument("--client")
            command.add_argument("--project")
            command.add_argument("--task")
        if name == "export":
            command.add_argument("--project")
            command.add_argument("--client")

    rows = commands.add_parser("report-rows", help="Billing report rows with amounts that add up to the invoice")
    rows.add_argument("--period", choices=("week", "month"), default="month")
    rows.add_argument("--start", help="Inclusive local date (YYYY-MM-DD)")
    rows.add_argument("--end", help="Exclusive local date (YYYY-MM-DD)")
    rows.add_argument("--client")
    rows.add_argument("--project", action="append", help="Limit to this project (repeatable)")

    group = commands.add_parser("assign-group", help="Assign a group of agent entries in a selected time range")
    group.add_argument("target")
    group.add_argument("--provider", required=True, type=importers.harness_id)
    group.add_argument("--folder")
    group.add_argument("--branch")
    group.add_argument("--project")
    group.add_argument("--task")
    group.add_argument("--start", required=True)
    group.add_argument("--end", required=True)
    group.add_argument("--save-folder", action="store_true")

    git = commands.add_parser("github", help="Configure and fetch GitHub pull request metadata")
    git_commands = git.add_subparsers(dest="action", required=True)
    git_commands.add_parser("status", help="Check GitHub CLI authentication")
    repo = git_commands.add_parser("set")
    repo.add_argument("project")
    repo.add_argument("repo")
    refresh = git_commands.add_parser("refresh")
    refresh.add_argument("project")
    refresh.add_argument("--repo", help="Link this repository only after its pull requests can be loaded")
    unlink = git_commands.add_parser("unlink", help="Remove the repository link and its cached pull requests")
    unlink.add_argument("project")
    pr_route = git_commands.add_parser("route-pr", help="Route a pull request to a connected project")
    pr_route.add_argument("project")
    pr_route.add_argument("number", type=int)
    pr_route.add_argument("--remove", action="store_true")

    entries = commands.add_parser("entries", help="Inspect captured metadata and IDs for corrections")
    entries.add_argument("--period", choices=("week", "month"), default="week")
    entries.add_argument("--start")
    entries.add_argument("--end")
    entries.add_argument("--project")
    entries.add_argument("--unassigned", action="store_true")
    entries.add_argument("--limit", type=int, default=50)

    activity = commands.add_parser("focus", help="Record or review foreground app time")
    focus_actions = activity.add_subparsers(dest="action", required=True)
    timeline = focus_actions.add_parser("timeline")
    timeline.add_argument("--day")
    timeline.add_argument("--week", action="store_true", help="Show the Monday-to-Sunday week containing the selected day")
    focus_actions.add_parser("record", help="Read activity blocks as JSON from stdin")
    focus_actions.add_parser("recover", help=argparse.SUPPRESS)
    preferences = focus_actions.add_parser("config", help="Read tracking preferences and keyword rules")
    preferences.add_argument("--enabled", choices=("on", "off"))
    chrome_client = focus_actions.add_parser("chrome-client", help="Set the fallback client for a Chrome profile")
    chrome_client.add_argument("profile_id")
    destination = chrome_client.add_mutually_exclusive_group(required=True)
    destination.add_argument("--client")
    destination.add_argument("--clear", action="store_true")
    rule = focus_actions.add_parser("save-rule", help="Assign or ignore future app, window, domain, or URL activity")
    rule.add_argument("--id")
    action = rule.add_mutually_exclusive_group(required=True)
    action.add_argument("--project")
    action.add_argument("--ignore", action="store_true")
    rule.add_argument("--field", choices=("app", "window", "domain", "url"), required=True)
    rule.add_argument("--keyword", required=True)
    rule.add_argument("--app-scope")
    rule.add_argument("--app-id")
    rule.add_argument("--chrome-profile")
    rule.add_argument("--tag")
    delete_rule = focus_actions.add_parser("delete-rule")
    delete_rule.add_argument("id")
    automatic = focus_actions.add_parser("auto-rules", help="Turn a project's automatic name rules on or off")
    automatic.add_argument("project")
    automatic.add_argument("--state", choices=("on", "off"), required=True)
    classify = focus_actions.add_parser("classify")
    classify.add_argument("id")
    disposition = classify.add_mutually_exclusive_group(required=True)
    disposition.add_argument("--project")
    disposition.add_argument("--ignore", action="store_true")
    disposition.add_argument("--unassign", action="store_true")

    commands.add_parser("mcp", help="Serve tracker tools via stdio")
    return cli


def print_json(result):
    print(json.dumps(result, ensure_ascii=False, indent=2))


def add_manual(conn, args):
    store.get_project(conn, args.project)
    if args.at:
        tz = store.zone(store.setting(conn, "timezone", "UTC"))
        at = store.parse_at(args.at, tz)
        if at is None:
            raise ValueError("Use an ISO date or timestamp for --at")
    else:
        at = int(datetime.now(timezone.utc).timestamp() * 1000)
    if args.command == "time":
        event = dict(kind="human", millis=store.duration_millis(args.minutes), label=args.activity)
    else:
        event = dict(kind="expense", label=store.required(args.description, "Description"),
                     cents=store.cents(args.amount), reimbursable=int(args.reimburse))
    entry_id = f"{args.command}:{uuid4().hex}"
    store.add_entry(conn, dict(
        event, id=entry_id, at=at, task=args.task, project=args.project,
    ))
    print(entry_id)


def run(conn, args):
    command = args.command
    if command == "init":
        name = args.timezone
        if args.default_timezone and store.setting(conn, "timezone", None) is None:
            name = args.default_timezone
        if name:
            store.zone(name)
            store.set_setting(conn, "timezone", name)
        if args.currency:
            code = args.currency.upper()
            if not re.fullmatch(r"[A-Z]{3}", code):
                raise ValueError("Use a three-letter currency code")
            current = store.setting(conn, "currency", "EUR")
            has_money = conn.execute("SELECT 1 FROM entries WHERE kind = 'expense' "
                                     "UNION ALL SELECT 1 FROM rates UNION ALL SELECT 1 FROM model_rates "
                                     "UNION ALL SELECT 1 FROM subscriptions "
                                     "UNION ALL SELECT 1 FROM billing_terms LIMIT 1")
            if code != current and has_money.fetchone():
                raise ValueError("Currency is fixed once expenses, rates, or subscriptions exist in this ledger")
            store.set_setting(conn, "currency", code)
        print_json({"database": str(args.db), "currency": store.setting(conn, "currency", "EUR"),
                    "timezone": store.setting(conn, "timezone", "UTC")})
    elif command == "project":
        if args.action == "add":
            if args.new_only:
                conn.execute("BEGIN IMMEDIATE")
                if conn.execute("SELECT 1 FROM projects WHERE name = ?", (args.name.strip(),)).fetchone():
                    raise ValueError("A project with this name already exists")
            store.create_project(conn, args.name, args.client, args.kind, args.folder)
            if args.github:
                github.set_repo(conn, args.name.strip(), args.github)
        elif args.action == "map":
            store.map_folder(conn, args.name, args.folder)
        elif args.action == "unmap":
            store.unmap_folder(conn, args.name, args.folder)
        else:
            print_json(store.project_list(conn))
    elif command in ("time", "expense"):
        add_manual(conn, args)
    elif command == "client":
        if args.action == "save":
            store.save_client(conn, args.name, args.previous)
        print_json(store.client_list(conn))
    elif command == "appearance":
        scope, name = ("client", args.client) if args.client is not None else ("project", args.project)
        store.set_appearance(conn, scope, name, args.db.parent / "icons", color=args.color, icon=args.icon)
        print_json(store.appearance_list(conn))
    elif command == "billing":
        if args.action == "set":
            scope, name = ("client", args.client) if args.client is not None else ("project", args.project)
            billing.save_terms(conn, scope, name, args.human_rate, args.agent_mode, args.agent_rate,
                               args.markup, args.cap)
        elif args.action == "exchange-rate":
            billing.set_exchange_rate(conn, args.rate)
        if args.action == "summary":
            _, entries = reports.scope(conn, args.start, args.end, args.period)
            print_json(billing.summary(conn, entries))
        else:
            print_json(billing.terms_listing(conn))
    elif command == "model-rate":
        store.model_rate(conn, args.provider, args.model, (args.input, args.cached, args.cache_write, args.output))
    elif command == "refresh-prices":
        print_json(pricing.refresh(conn, if_stale=args.if_stale))
    elif command == "openrouter-sync":
        if args.clear:
            openrouter.clear(conn)
        else:
            key = sys.stdin.read(1024) if args.key_stdin else os.getenv("OPENROUTER_MANAGEMENT_KEY", "")
            print_json(openrouter.refresh(conn, key))
    elif command == "subscription":
        if args.action in ("set", "remove"):
            store.set_subscription(conn, args.name, getattr(args, "monthly", None),
                                   getattr(args, "provider", None), getattr(args, "new_only", False))
        print_json({"currency": store.setting(conn, "currency", "EUR"), **store.subscriptions(conn)})
    elif command == "toggl" and args.action in ("workspace", "unlink"):
        if args.action == "workspace":
            print_json(toggl.choose_workspace(conn, args.id))
        else:
            toggl.unlink(conn)
    elif command == "toggl":
        key = sys.stdin.read(1024)
        if args.action == "link":
            print_json(toggl.link(conn, key, args.workspace))
        elif args.action == "projects":
            print_json(toggl.projects(key))
        else:
            print_json(toggl.import_time(conn, key, args.source, args.project, args.start, args.end))
    elif command == "import-harness":
        print_json(importers.import_harness(conn, args.name, sys.stdin))
    elif command == "assign":
        store.assign(conn, args.entry_id, args.project)
    elif command == "assign-group":
        print_json(desktop.assign_group(
            conn, args.target, args.provider, args.folder, args.branch, args.project, args.task,
            args.start, args.end, args.save_folder,
        ))
    elif command == "github":
        if args.action == "status":
            print_json(github.auth_status())
        elif args.action == "set":
            print_json({"repo": github.set_repo(conn, args.project, args.repo)})
        elif args.action == "refresh":
            print_json(github.refresh(conn, args.project, args.repo))
        elif args.action == "unlink":
            github.unlink(conn, args.project)
        else:
            print_json(github.set_pr_route(conn, args.project, args.number, args.remove))
    elif command == "focus":
        if args.action == "timeline":
            print_json(focus.timeline(conn, args.day, week=args.week))
        elif args.action == "record":
            focus.record(conn, json.load(sys.stdin))
        elif args.action == "recover":
            focus.close_interrupted(conn)
        elif args.action == "config":
            if args.enabled:
                store.set_setting(conn, "focus_enabled", "1" if args.enabled == "on" else "0")
            print_json(focus.config(conn))
        elif args.action == "chrome-client":
            focus.set_chrome_profile_client(conn, args.profile_id, args.client)
            print_json(focus.config(conn))
        elif args.action == "save-rule":
            focus.save_rule(conn, args.project, args.field, args.keyword, args.app_scope, args.tag, args.id,
                            chrome_profile=args.chrome_profile, app_id=args.app_id)
            print_json(focus.config(conn))
        elif args.action == "delete-rule":
            conn.execute("DELETE FROM focus_rules WHERE id = ?", (args.id,))
            print_json(focus.config(conn))
        elif args.action == "auto-rules":
            focus.set_auto_rules(conn, args.project, args.state == "on")
            print_json(focus.config(conn))
        else:
            focus.classify(conn, args.id, args.project, args.ignore)
    elif command == "remove":
        change = conn.execute("DELETE FROM entries WHERE id = ? AND kind IN ('human', 'expense')", (args.entry_id,))
        if not change.rowcount:
            raise ValueError("No manual entry with that ID")
    elif command == "sync":
        print_json(importers.sync(conn, args.provider, args.codex_dir, args.claude_dir, args.recent_days,
                                  opencode=args.opencode_db, rescan=args.rescan))
    elif command == "blocks":
        if not 1 <= args.hours <= 24 * 366:
            raise ValueError("Hours must be between 1 and 8784")
        # TRACKER_NOW (epoch milliseconds) pins the clock, for comparing engines on the same windows.
        now = int(os.environ["TRACKER_NOW"]) if os.environ.get("TRACKER_NOW", "").isdigit() else None
        print_json(blocks.usage_blocks(conn, args.hours, args.active, now=now))
    elif command == "entries":
        if args.limit < 1:
            raise ValueError("Limit must be positive")
        bounds, rows = reports.scope(conn, args.start, args.end, args.period)
        rows = [e for e in rows if (args.project is None or e["project"] == args.project)
                and (not args.unassigned or e["project"] is None)]
        print_json({**bounds, "entry_count": len(rows), "entries": rows[-args.limit:]})
    elif command == "report-rows":
        print_json(report_rows.build(conn, args.start, args.end, args.period, args.client, args.project))
    elif command in ("report", "review", "snapshot", "export"):
        dates = dict(start=args.start, end=args.end, period=args.period)
        if command == "review":
            print_json(reports.review(conn, **dates))
        elif command == "report":
            result = reports.report(conn, client=args.client, project=args.project, task=args.task, **dates)
            print_json(result) if args.as_json else print(reports.render_report(result))
        elif command == "snapshot":
            print_json({**desktop.snapshot(conn, **dates), "database": str(args.db)})
        else:
            sys.stdout.write(desktop.export_csv(conn, project=args.project, client=args.client, **dates))


def main():
    args = parser().parse_args()
    args.db = args.db.expanduser().resolve() if args.db else store.db_path()
    try:
        if args.command == "mcp":
            from .mcp import serve
            serve(args.db, sys.stdin, sys.stdout)
        else:
            with store.database(args.db) as conn:
                run(conn, args)
    except (ValueError, OSError, sqlite3.Error) as error:
        print(f"tracker: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
