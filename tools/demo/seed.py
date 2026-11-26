#!/usr/bin/env python3
"""Fill a fresh Daylanes ledger with fictional sample data, for screenshots, videos and trying the app.

Usage: seed.py --db PATH --cli PATH/TO/TrackerCLI [--home DEMO_HOME]

Every client, project, repository and person here is made up. The data is laid out relative to now:
two weeks of workdays, plus today up to the current time, so the Day view always looks lived in.
Run it only against an empty, throwaway ledger (bin/demo does that). It never touches the default ledger.
"""
import argparse
import json
import os
import pwd
import random
import sqlite3
import subprocess
import sys
import uuid
from datetime import date, datetime, time, timedelta
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python 3.8
    ZoneInfo = None

# ---------- The cast (fictional) ----------

CLIENTS = {
    "Northwind Studio": {"icon": "paintbrush", "human": "90", "agent_mode": "time", "agent_rate": "35"},
    "Lumen Health": {"icon": "cross.case", "human": "110", "agent_mode": "usage", "markup": "20"},
    "Me": {"icon": "person", "human": None},
}

PROJECTS = {
    "Northwind web": {"client": "Northwind Studio", "kind": "billable", "color": "#3E8BFF",
                      "folders": ["northwind-web"], "repo": "northwind/web"},
    "Lumen app": {"client": "Lumen Health", "kind": "billable", "color": "#2AC561",
                  "folders": ["lumen-app", "lumen-data"], "repo": "lumen/app"},
    "Brand sprint": {"client": "Lumen Health", "kind": "billable", "color": "#8B5AF3",
                     "folders": ["brand-docs"], "repo": None},
    "Daylanes": {"client": "Me", "kind": "internal", "color": "#F4A02A",
                 "folders": ["daylanes"], "repo": "daylanes/app"},
}

PRS = [  # project, number, branch, title, state
    ("Northwind web", 142, "checkout-v2", "Checkout redesign", "open"),
    ("Northwind web", 139, "invoice-rounding", "Fix invoice rounding", "merged"),
    ("Northwind web", 145, "a11y-forms", "Accessible form errors", "open"),
    ("Lumen app", 58, "onboarding", "Onboarding emails", "open"),
    ("Lumen app", 55, "appointments-sync", "Sync appointments offline", "merged"),
    ("Daylanes", 31, "menu-bar", "Menu bar quick glance", "merged"),
]

APPS = {  # bundle id, name
    "figma": ("com.figma.Desktop", "Figma"),
    "slack": ("com.tinyspeck.slackmacgap", "Slack"),
    "xcode": ("com.apple.dt.Xcode", "Xcode"),
    "cursor": ("com.todesktop.230313mzl4w4u92", "Cursor"),
    "chrome": ("com.google.Chrome", "Google Chrome"),
    "zoom": ("us.zoom.xos", "zoom.us"),
    "mail": ("com.apple.mail", "Mail"),
    "linear": ("com.linear", "Linear"),
    "notes": ("com.apple.Notes", "Notes"),
    "terminal": ("com.mitchellh.ghostty", "Ghostty"),
}

# A workday: (start hour, minutes, app, project or None for "to review", PR number or None)
DAY_PLANS = [
    [(9.0, 25, "mail", None, None), (9.45, 80, "figma", "Northwind web", None), (10.8, 20, "slack", "Lumen app", None),
     (11.15, 85, "xcode", "Daylanes", None), (13.5, 35, "mail", None, None), (14.15, 100, "chrome", "Northwind web", 142),
     (16.0, 45, "zoom", "Brand sprint", None), (16.9, 55, "cursor", "Lumen app", 58), (17.9, 25, "linear", "Northwind web", None)],
    [(8.75, 30, "slack", None, None), (9.3, 95, "cursor", "Lumen app", 58), (11.0, 30, "zoom", "Lumen app", None),
     (11.6, 60, "figma", "Brand sprint", None), (13.75, 70, "chrome", "Northwind web", 145), (15.0, 25, "notes", None, None),
     (15.5, 90, "xcode", "Daylanes", None), (17.1, 40, "linear", "Northwind web", None)],
    [(9.2, 45, "figma", "Northwind web", None), (10.0, 20, "slack", "Northwind web", None), (10.4, 110, "terminal", "Daylanes", 31),
     (13.3, 50, "zoom", "Brand sprint", None), (14.3, 80, "cursor", "Lumen app", 55), (15.75, 30, "mail", None, None),
     (16.4, 75, "chrome", "Northwind web", 139)],
]

# Agent threads: provider, folder, branch, model, start hour, (turn minutes...), gap minutes between turns
AGENT_PLANS = [
    [("claude", "northwind-web", "checkout-v2", "claude-opus-4-8", 9.6, [14, 22, 9, 31, 12], 6),
     ("claude", "lumen-app", "onboarding", "claude-opus-4-8", 10.1, [18, 11, 26, 8], 9),
     ("codex", "daylanes", "menu-bar", "gpt-5.5", 11.3, [12, 25, 17], 7),
     ("claude", "lumen-data", None, "claude-sonnet-4-5", 13.9, [20, 15, 10], 5),
     ("codex", "brand-docs", None, "gpt-5.5", 14.4, [9, 14, 21, 6], 8),
     ("opencode", "lumen-data", "cleanup", "claude-sonnet-4-5", 15.2, [16, 12], 10),
     ("claude", "northwind-web", "a11y-forms", "claude-opus-4-8", 16.2, [24, 13, 19], 6)],
    [("codex", "lumen-app", "onboarding", "gpt-5.5", 9.1, [21, 14, 30], 8),
     ("claude", "northwind-web", "a11y-forms", "claude-opus-4-8", 9.5, [17, 28, 12, 9], 7),
     ("claude", "daylanes", None, "claude-opus-4-8", 11.4, [11, 19, 22], 6),
     ("codex", "northwind-web", "checkout-v2", "gpt-5.5", 13.8, [26, 12, 15], 9),
     ("claude", "brand-docs", None, "claude-sonnet-4-5", 15.1, [13, 9], 12)],
    [("claude", "daylanes", "menu-bar", "claude-opus-4-8", 9.0, [19, 24, 15, 11], 5),
     ("codex", "northwind-web", "invoice-rounding", "gpt-5.5", 10.2, [15, 20, 8], 6),
     ("claude", "lumen-app", "appointments-sync", "claude-opus-4-8", 13.6, [28, 16, 21], 8),
     ("opencode", "lumen-data", None, "claude-sonnet-4-5", 14.0, [12, 18], 9),
     ("codex", "brand-docs", None, "gpt-5.5", 16.0, [14, 10, 17], 7)],
]

DIARY = {
    "Northwind web": [
        {"headline": "Checkout redesign is ready for review",
         "summary": "The new checkout landed behind a flag, so Northwind can try it with real carts before launch.",
         "standup": "Yesterday I finished the checkout redesign for Northwind. The new flow is behind a flag, so their team can "
                    "test it with real carts this week without touching the live store. The agent wrote most of the form "
                    "validation and I reviewed every step on mobile. The only open question is the shipping copy, which "
                    "waits on their marketing lead. Today I'll fix the review notes and start on accessible form errors.",
         "outcomes": "- Checkout v2 behind the `checkout_v2` flag (PR #142)\n- Card errors now show inline, not in an alert",
         "decisions": "- Keep guest checkout as the default path",
         "blockers": "- Shipping copy: waiting on Northwind marketing since Tuesday",
         "next_steps": "- Address review notes on #142\n- Start #145 accessible form errors",
         "sources": [{"title": "PR #142 Checkout redesign", "url": "https://github.com/northwind/web/pull/142"}]},
        {"headline": "Invoice rounding fixed and shipped",
         "summary": "Totals now match the accounting export to the cent, which closes the support thread from last week.",
         "outcomes": "- PR #139 merged and deployed\n- Added tests for three currencies",
         "next_steps": "- Watch the export for a week\n- Pair on checkout layout with the designer",
         "sources": [{"title": "PR #139 Fix invoice rounding", "url": "https://github.com/northwind/web/pull/139"}]},
        {"headline": "Checkout layout agreed with the design team",
         "summary": "One review call settled the layout, so the build can start without more rounds of mockups.",
         "decisions": "- Two steps instead of three\n- Order summary stays visible on desktop",
         "next_steps": "- Build the address step first"},
    ],
    "Lumen app": [
        {"headline": "Onboarding emails drafted and wired up",
         "summary": "New patients now get three short emails in their first week, written with Lumen's care team.",
         "standup": "Yesterday was Lumen onboarding. The three welcome emails are drafted and wired to the signup event, "
                    "and Claude Code handled the template plumbing while I worked on the copy with their care team. "
                    "Nothing is blocked. Today I'll add the unsubscribe flow and send previews to their team.",
         "outcomes": "- Email templates and triggers in PR #58\n- Preview build sent to the care team",
         "next_steps": "- Unsubscribe flow\n- Localised copy for Spanish",
         "sources": [{"title": "PR #58 Onboarding emails", "url": "https://github.com/lumen/app/pull/58"}]},
        {"headline": "Offline appointment sync merged",
         "summary": "Appointments booked without signal now sync when the phone reconnects, the top request from clinics.",
         "outcomes": "- PR #55 merged\n- Conflict rule: the newest change wins, with a note to the patient",
         "sources": [{"title": "PR #55 Sync appointments offline", "url": "https://github.com/lumen/app/pull/55"}]},
    ],
}


# ---------- Helpers ----------

def local_zone():
    name = os.environ.get("TZ")
    if not name:
        try:
            link = os.readlink("/etc/localtime")
            name = link.split("zoneinfo/", 1)[1] if "zoneinfo/" in link else None
        except OSError:
            name = None
    if ZoneInfo and name:
        try:
            return ZoneInfo(name), name
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo, "UTC"


def millis(moment):
    return int(moment.timestamp() * 1000)


def run_cli(cli, db, *args):
    result = subprocess.run([cli, "--db", db, *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"seed: `{' '.join(args)}` failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def workdays(today, count):
    days, day = [], today - timedelta(days=1)
    while len(days) < count:
        if day.weekday() < 5:
            days.append(day)
        day -= timedelta(days=1)
    return list(reversed(days))


def make_repo(path, repo):
    """An empty git repo per sample folder, so the app never walks up into a real checkout around the demo."""
    os.makedirs(path, exist_ok=True)
    git = ["git", "-C", path, "-c", "user.name=Sample", "-c", "user.email=sample@example.com"]
    subprocess.run(git + ["init", "-q", "-b", "main"], check=True, capture_output=True)
    if repo:
        subprocess.run(git + ["remote", "add", "origin", f"https://github.com/{repo}.git"], capture_output=True)
    subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "Initial commit"], check=True, capture_output=True)


# ---------- Seeding ----------

def configure(cli, db, home, zone_name):
    run_cli(cli, db, "init", "--timezone", zone_name, "--currency", "USD")
    for name in CLIENTS:
        run_cli(cli, db, "client", "save", name)
    for name, project in PROJECTS.items():
        args = ["project", "add", name, "--client", project["client"], "--kind", project["kind"]]
        run_cli(cli, db, *args)
        for folder in project["folders"]:
            path = os.path.join(home, "Code", folder)
            make_repo(path, project["repo"])
            run_cli(cli, db, "project", "map", name, path)
        run_cli(cli, db, "appearance", "--project", name, "--color", project["color"])
    for name, client in CLIENTS.items():
        if client.get("icon"):
            subprocess.run([cli, "--db", db, "appearance", "--client", name, "--icon", client["icon"]], capture_output=True)
        if client.get("human"):
            args = ["billing", "set", "--client", name, "--human-rate", client["human"], "--agent-mode", client["agent_mode"]]
            if client.get("agent_rate"):
                args += ["--agent-rate", client["agent_rate"]]
            if client.get("markup"):
                args += ["--markup", client["markup"]]
            run_cli(cli, db, *args)
    run_cli(cli, db, "subscription", "set", "Claude Max", "--monthly", "200", "--provider", "claude")
    run_cli(cli, db, "subscription", "set", "ChatGPT Pro", "--monthly", "200", "--provider", "codex")


def folder_project(home):
    mapping = {}
    for name, project in PROJECTS.items():
        for folder in project["folders"]:
            mapping[folder] = (name, os.path.join(home, "Code", folder))
    return mapping


def seed_activity(con, home, zone, today, now):
    rng = random.Random(20261126)
    folders = folder_project(home)
    blocks, entries, links = [], [], []
    days = [(day, False) for day in workdays(today, 10)]
    rich_today = now.hour * 60 + now.minute >= 9 * 60 + 40 and today.weekday() < 5
    if rich_today or today.weekday() >= 5:
        days.append((today, True))
    for index, (day, is_today) in enumerate(days):
        plan = DAY_PLANS[index % len(DAY_PLANS)] if not is_today else DAY_PLANS[0]
        agents = AGENT_PLANS[index % len(AGENT_PLANS)] if not is_today else AGENT_PLANS[0]
        start_of_day = datetime.combine(day, time(0), tzinfo=zone)
        limit = now - timedelta(minutes=4) if is_today else None
        for hour, minutes, app, project, pr in plan:
            jitter = 0 if is_today else rng.randint(-6, 6)
            start = start_of_day + timedelta(hours=hour, minutes=jitter)
            end = start + timedelta(minutes=minutes + (0 if is_today else rng.randint(-8, 8)))
            if limit and start >= limit:
                continue
            if limit and end > limit:
                end = limit
            # Past days are mostly sorted out already; leave one or two for review.
            if project is None and not is_today and rng.random() < 0.6:
                project = rng.choice(["Northwind web", "Lumen app"])
            block_id = str(uuid.uuid4())
            app_id, app_name = APPS[app]
            blocks.append((block_id, app_id, app_name, millis(start), millis(end), 1, project, 0))
            if pr:
                pr_project = next(x[0] for x in PRS if x[1] == pr)
                links.append((block_id, PROJECTS[pr_project]["repo"], pr))
        for thread_index, (provider, folder, branch, model, hour, turns, gap) in enumerate(agents):
            project, path = folders[folder]
            session = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{day}-{thread_index}-{provider}-{folder}"))
            at = start_of_day + timedelta(hours=hour, minutes=0 if is_today else rng.randint(-10, 10))
            for turn_index, minutes in enumerate(turns):
                minutes = minutes if is_today else max(4, minutes + rng.randint(-4, 4))
                end = at + timedelta(minutes=minutes)
                if is_today and end > now - timedelta(minutes=1):
                    break
                turn = f"{session}-{turn_index}"
                common = {"provider": provider, "session": session, "folder": path, "branch": branch,
                          "project": project, "model": model}
                entries.append(dict(common, id=f"demo:{turn}:runtime", kind="runtime", at=millis(at),
                                    millis=minutes * 60_000, label="turn elapsed"))
                tokens_in = rng.randint(1_800, 9_000) * minutes // 4
                cached = tokens_in * rng.randint(6, 14)
                output = rng.randint(900, 3_500) * minutes // 4
                price = {"claude-opus-4-8": (5, 0.5, 25), "claude-sonnet-4-5": (3, 0.3, 15), "gpt-5.5": (2.5, 0.25, 15)}[model]
                usd = (tokens_in * price[0] + cached * price[1] + output * price[2]) / 1_000_000
                entries.append(dict(common, id=f"demo:{turn}:usage", kind="usage", at=millis(end - timedelta(seconds=20)),
                                    input=tokens_in, cached=cached, output=output, prompt_tokens=tokens_in + cached,
                                    recorded_usd=f"{usd:.4f}"))
                at = end + timedelta(minutes=gap if is_today else max(2, gap + rng.randint(-3, 3)))
        # A call logged by hand on some days.
        if index % 3 == 1:
            at = start_of_day + timedelta(hours=12, minutes=15)
            entries.append({"id": f"demo:{day}:call", "kind": "human", "at": millis(at), "project": "Brand sprint",
                            "millis": 30 * 60_000, "label": "other", "task": "Workshop with Lumen's care team"})

    con.executemany("INSERT INTO focus_blocks (id, app_id, app_name, started_at, ended_at, closed, project, ignored) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", blocks)
    con.executemany("INSERT INTO focus_github (block_id, repo, number) VALUES (?, ?, ?)", links)
    for entry in entries:
        columns = ", ".join(entry)
        con.execute(f"INSERT INTO entries ({columns}) VALUES ({', '.join('?' for _ in entry)})", list(entry.values()))
    # An expense: a stock photo licence for the brand sprint.
    expense_day = workdays(today, 4)[0]
    con.execute("INSERT INTO entries (id, kind, at, project, label, cents, reimbursable) VALUES (?, 'expense', ?, ?, ?, ?, 1)",
                ("demo:expense:photos", millis(datetime.combine(expense_day, time(15), tzinfo=zone)), "Brand sprint",
                 "Stock photo licence", 4900))
    return len(blocks), len(entries)


def seed_github(con, now):
    stamp = millis(now)
    for name, project in PROJECTS.items():
        if project["repo"]:
            con.execute("INSERT OR REPLACE INTO github_projects (project, repo, refreshed_at) VALUES (?, ?, ?)",
                        (name, project["repo"], stamp))
    for project, number, branch, title, state in PRS:
        url = f"https://github.com/{PROJECTS[project]['repo']}/pull/{number}"
        con.execute("INSERT OR REPLACE INTO github_prs (project, number, branch, title, state, url) VALUES (?, ?, ?, ?, ?, ?)",
                    (project, number, branch, title, state, url))


def seed_rules(con):
    rules = [("app", "Figma", None, "Design", "Northwind web"),
             ("domain", "github.com/northwind", None, None, "Northwind web"),
             ("app", "Xcode", None, None, "Daylanes"),
             ("window", "Lumen", None, "Calls", "Lumen app")]
    for field, keyword, scope, tag, project in rules:
        con.execute("INSERT INTO focus_rules (id, field, keyword, app_scope, tag, project) VALUES (?, ?, ?, ?, ?, ?)",
                    (str(uuid.uuid4()), field, keyword, scope, tag, project))


def seed_diary(con, zone, zone_name, today):
    cutoff = time(5)
    days = list(reversed(workdays(today, 6)))
    for project, notes in DIARY.items():
        routine = {"id": str(uuid.uuid4()).upper(), "agent": "claude" if project == "Lumen app" else "codex",
                   "brief": "Review my work for this project and write the day's diary.", "firstDay": days[-1].isoformat()}
        con.execute("INSERT INTO diary_routines (project, id, profile) VALUES (?, ?, ?)",
                    (project, routine["id"], json.dumps(routine)))
        for day, note in zip(days, notes):
            start = datetime.combine(day, cutoff, tzinfo=zone)
            end = datetime.combine(day + timedelta(days=1), cutoff, tzinfo=zone)
            window = {"start": millis(start), "end": millis(end), "timezone": zone_name}
            con.execute("INSERT INTO diary_entries (project, work_date, window, through, revision, content) "
                        "VALUES (?, ?, ?, ?, 1, ?)",
                        (project, day.isoformat(), json.dumps(window), millis(end), json.dumps(note)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", required=True)
    parser.add_argument("--cli", required=True, help="path to TrackerCLI")
    parser.add_argument("--home", default=None, help="folder for the sample project folders")
    args = parser.parse_args()
    db = os.path.abspath(args.db)
    # HOME points at the demo home here, so compare with the account's real home folder.
    real = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".local/share/tracker/ledger.sqlite3")
    if os.path.exists(db) and os.path.getsize(db) > 0:
        sys.exit(f"seed: {db} already exists. Seed only a new, empty ledger.")
    if os.path.realpath(db) == os.path.realpath(real):
        sys.exit("seed: refusing to write to the default ledger.")
    home = args.home or os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(db))))
    zone, zone_name = local_zone()
    now = datetime.now(zone)
    configure(args.cli, db, home, zone_name)
    con = sqlite3.connect(db)
    con.execute("PRAGMA foreign_keys = ON")
    with con:
        counts = seed_activity(con, home, zone, now.date(), now)
        seed_github(con, now)
        seed_rules(con)
        seed_diary(con, zone, zone_name, now.date())
    con.close()
    print(f"seed: {counts[0]} activity blocks and {counts[1]} agent and manual entries in {db}")


if __name__ == "__main__":
    main()
