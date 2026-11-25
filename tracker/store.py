import os
import re
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import github

FOCUS_RULES_SCHEMA = """
CREATE TABLE IF NOT EXISTS focus_rules (
    id TEXT PRIMARY KEY, field TEXT NOT NULL CHECK(field IN ('app', 'window', 'domain', 'url')),
    keyword TEXT NOT NULL, app_scope TEXT, tag TEXT,
    project TEXT REFERENCES projects(name), chrome_profile TEXT, app_id TEXT
);
"""

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS clients (name TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS projects (
    name TEXT PRIMARY KEY, client TEXT,
    kind TEXT NOT NULL CHECK(kind IN ('billable','internal','personal'))
);
CREATE TABLE IF NOT EXISTS folders (
    path TEXT PRIMARY KEY, project TEXT NOT NULL REFERENCES projects(name)
);
CREATE TABLE IF NOT EXISTS rates (
    scope TEXT NOT NULL, name TEXT NOT NULL, meter TEXT NOT NULL, cents INTEGER NOT NULL,
    PRIMARY KEY (scope, name, meter)
);
CREATE TABLE IF NOT EXISTS model_rates (
    provider TEXT NOT NULL, model TEXT NOT NULL,
    input INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL, PRIMARY KEY (provider, model)
);
CREATE TABLE IF NOT EXISTS subscriptions (
    name TEXT PRIMARY KEY, monthly_cents INTEGER NOT NULL CHECK(monthly_cents >= 0), provider TEXT
);
CREATE TABLE IF NOT EXISTS toggl_time (
    id INTEGER NOT NULL, account INTEGER NOT NULL, toggl_project INTEGER NOT NULL,
    project TEXT NOT NULL REFERENCES projects(name), started_at INTEGER NOT NULL,
    ended_at INTEGER NOT NULL CHECK(ended_at > started_at), PRIMARY KEY (account, id)
);
CREATE INDEX IF NOT EXISTS toggl_time_ends ON toggl_time(ended_at);
CREATE INDEX IF NOT EXISTS toggl_time_import ON toggl_time(account, toggl_project, started_at);
CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL,
    at INTEGER NOT NULL, provider TEXT, model TEXT, session TEXT,
    folder TEXT, branch TEXT, task TEXT, project TEXT REFERENCES projects(name),
    label TEXT, millis INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL DEFAULT 0,
    cached INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
    output INTEGER NOT NULL DEFAULT 0, cents INTEGER, reimbursable INTEGER NOT NULL DEFAULT 0,
    prompt_tokens INTEGER, cache_write_1h INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0,
    tier TEXT, recorded_usd TEXT, web_searches INTEGER NOT NULL DEFAULT 0, dedupe_key TEXT,
    replica INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS entries_at ON entries(at);
CREATE TABLE IF NOT EXISTS focus_blocks (
    id TEXT PRIMARY KEY, app_id TEXT NOT NULL, app_name TEXT NOT NULL,
    started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL CHECK (ended_at > started_at),
    closed INTEGER NOT NULL CHECK (closed IN (0, 1)),
    project TEXT REFERENCES projects(name), ignored INTEGER NOT NULL DEFAULT 0 CHECK (ignored IN (0, 1))
);
CREATE INDEX IF NOT EXISTS focus_ends ON focus_blocks(ended_at);
""" + FOCUS_RULES_SCHEMA + """
CREATE TABLE IF NOT EXISTS focus_matches (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    field TEXT NOT NULL, keyword TEXT NOT NULL, tag TEXT
);
CREATE TABLE IF NOT EXISTS sources (
    path TEXT PRIMARY KEY, signature TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS github_projects (
    project TEXT PRIMARY KEY REFERENCES projects(name), repo TEXT NOT NULL, refreshed_at INTEGER
);
CREATE TABLE IF NOT EXISTS github_prs (
    project TEXT NOT NULL REFERENCES github_projects(project), number INTEGER NOT NULL,
    branch TEXT NOT NULL, title TEXT NOT NULL, state TEXT NOT NULL, url TEXT NOT NULL,
    PRIMARY KEY (project, number)
);
CREATE TABLE IF NOT EXISTS github_pr_routes (
    repo TEXT COLLATE NOCASE NOT NULL, number INTEGER NOT NULL,
    project TEXT NOT NULL REFERENCES github_projects(project),
    PRIMARY KEY (repo, number)
);
CREATE TABLE IF NOT EXISTS billing_terms (
    scope TEXT NOT NULL CHECK(scope IN ('client', 'project')), name TEXT NOT NULL,
    human_cents INTEGER, agent_mode TEXT CHECK(agent_mode IS NULL OR agent_mode IN ('none', 'time', 'usage', 'hybrid')),
    agent_cents INTEGER, usage_markup TEXT, monthly_cap_cents INTEGER,
    PRIMARY KEY (scope, name)
);
CREATE TABLE IF NOT EXISTS appearance (
    scope TEXT NOT NULL CHECK(scope IN ('client', 'project')), name TEXT NOT NULL,
    color TEXT, icon TEXT, PRIMARY KEY (scope, name)
);
CREATE TABLE IF NOT EXISTS focus_github (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    repo TEXT NOT NULL, number INTEGER
);
CREATE TABLE IF NOT EXISTS chrome_profile_clients (
    profile_id TEXT PRIMARY KEY, client TEXT NOT NULL REFERENCES clients(name) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS focus_clients (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    client TEXT NOT NULL REFERENCES clients(name) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS diary_routines (
    project TEXT PRIMARY KEY REFERENCES projects(name) ON UPDATE CASCADE ON DELETE CASCADE,
    id TEXT NOT NULL UNIQUE, profile TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS diary_entries (
    project TEXT NOT NULL REFERENCES projects(name) ON UPDATE CASCADE ON DELETE CASCADE,
    work_date TEXT NOT NULL, window TEXT NOT NULL, through INTEGER NOT NULL,
    revision INTEGER NOT NULL, content TEXT NOT NULL, edits TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (project, work_date)
);
CREATE INDEX IF NOT EXISTS diary_entries_work_date ON diary_entries(work_date);
"""
ENTRY_FIELDS = (
    "id", "kind", "at", "provider", "model", "session", "folder", "branch", "task", "project",
    "label", "millis", "input", "cached", "cache_write", "output", "cents", "reimbursable",
    # Largest single request (input + cache reads + cache writes) in a usage entry, for long-context prices.
    "prompt_tokens",
    # Usage detail for exact API values: 1-hour cache writes (part of cache_write), reasoning tokens
    # (part of output, for information), the service tier ("fast", "flex", ...), the cost the tool
    # itself recorded in USD, and paid web searches.
    "cache_write_1h", "reasoning", "tier", "recorded_usd", "web_searches",
    # A response that can appear in several logs (dedupe_key) and whether this copy is a replay of it.
    "dedupe_key", "replica",
)
ENTRY_COLUMNS = {
    "prompt_tokens": "INTEGER", "cache_write_1h": "INTEGER NOT NULL DEFAULT 0",
    "reasoning": "INTEGER NOT NULL DEFAULT 0", "tier": "TEXT", "recorded_usd": "TEXT",
    "web_searches": "INTEGER NOT NULL DEFAULT 0", "dedupe_key": "TEXT", "replica": "INTEGER NOT NULL DEFAULT 0",
}
TO_SECONDS = Decimal(1000)
TO_HOURS = Decimal(3600000)


def db_path():
    default = Path.home() / ".local" / "share" / "tracker" / "ledger.sqlite3"
    return Path(os.getenv("TRACKER_DB", str(default))).expanduser().resolve()


@contextmanager
def database(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists():
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        except FileExistsError:
            pass
    conn = sqlite3.connect(path, timeout=15)
    try:
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.executescript(SCHEMA)
        migrate_focus_rules(conn)
        migrate_entries(conn)
        migrate_settings_data(conn)
        migrate_self_client(conn)
        with conn:
            yield conn
    finally:
        conn.close()


SELF_CLIENT_DEFAULT = "Me"


def self_client(conn):
    """The client that stands for your own internal and personal work, so every project has a client."""
    return setting(conn, "self_client", SELF_CLIENT_DEFAULT)


def migrate_self_client(conn):
    if conn.execute("SELECT 1 FROM projects WHERE client IS NULL LIMIT 1").fetchone() is None:
        return
    with conn:
        name = self_client(conn)
        conn.execute("INSERT OR IGNORE INTO clients VALUES (?)", (name,))
        conn.execute("UPDATE projects SET client = ? WHERE client IS NULL", (name,))


def migrate_entries(conn):
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(entries)")}
    missing = [(name, kind) for name, kind in ENTRY_COLUMNS.items() if name not in existing]
    if missing:
        with conn:
            for name, kind in missing:
                conn.execute(f"ALTER TABLE entries ADD COLUMN {name} {kind}")
    conn.execute("CREATE INDEX IF NOT EXISTS entries_dedupe ON entries(dedupe_key) WHERE dedupe_key IS NOT NULL")


def migrate_focus_rules(conn):
    def needs_migration():
        schema = conn.execute("SELECT sql FROM sqlite_master WHERE name = 'focus_rules'").fetchone()
        project = next(row for row in conn.execute("PRAGMA table_info(focus_rules)") if row["name"] == "project")
        return "'domain'" not in schema["sql"] or project["notnull"]

    def columns():
        return {row["name"] for row in conn.execute("PRAGMA table_info(focus_rules)")}

    optional = ("chrome_profile", "app_id")
    if needs_migration() or not set(optional).issubset(columns()):
        with conn:
            conn.execute("BEGIN IMMEDIATE")
            existing = columns()
            if needs_migration():
                copied = ", ".join(("id", "field", "keyword", "app_scope", "tag", "project")
                                   + tuple(name for name in optional if name in existing))
                conn.execute("ALTER TABLE focus_rules RENAME TO old_focus_rules")
                conn.execute(FOCUS_RULES_SCHEMA)
                conn.execute(f"INSERT INTO focus_rules ({copied}) SELECT {copied} FROM old_focus_rules")
                conn.execute("DROP TABLE old_focus_rules")
            else:
                for name in optional:
                    if name not in existing:
                        conn.execute(f"ALTER TABLE focus_rules ADD COLUMN {name} TEXT")


def migrate_settings_data(conn):
    def needs_provider():
        return "provider" not in {row["name"] for row in conn.execute("PRAGMA table_info(subscriptions)")}

    if needs_provider():
        with conn:
            conn.execute("BEGIN IMMEDIATE")
            if needs_provider():
                conn.execute("ALTER TABLE subscriptions ADD COLUMN provider TEXT")


def required(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a nonempty string")
    return value.strip()


def setting(conn, key, fallback):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row[0] if row else fallback


def set_setting(conn, key, value):
    conn.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, value))


def zone(name):
    try:
        return ZoneInfo(name)
    except (ValueError, ZoneInfoNotFoundError):
        raise ValueError(f"Unknown time zone: {name}") from None


def parse_at(value, tz=timezone.utc):
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            stamp = int(value * 1000)
            datetime.fromtimestamp(stamp / 1000, timezone.utc)
            return stamp
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str):
        try:
            normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
            dt = datetime.fromisoformat(normalized)
            return int((dt if dt.tzinfo else dt.replace(tzinfo=tz)).timestamp() * 1000)
        except (ValueError, OverflowError, OSError):
            return None
    return None


def day_range(conn, start=None, end=None, period="week"):
    tz = zone(setting(conn, "timezone", "UTC"))
    today = datetime.now(tz).date()
    if start is None and end is None:
        if period == "month":
            first = today.replace(day=1)
            last = (first.replace(day=28) + timedelta(days=4)).replace(day=1)
        elif period == "week":
            first = today - timedelta(days=today.weekday())
            last = first + timedelta(days=7)
        else:
            raise ValueError("Period must be week or month")
    else:
        if not start or not end:
            raise ValueError("Provide both start and end dates (end is exclusive)")
        first, last = date.fromisoformat(start), date.fromisoformat(end)
    if first >= last:
        raise ValueError("End must be later than start")
    bounds = [int(datetime.combine(day, time.min, tz).timestamp() * 1000) for day in (first, last)]
    return first.isoformat(), last.isoformat(), *bounds


def cents(value):
    try:
        amount = Decimal(str(value))
        scaled = amount * 100
        if not amount.is_finite() or scaled != scaled.to_integral_value() or not 0 <= scaled <= 10**12:
            raise ValueError
        return int(scaled)
    except (InvalidOperation, ValueError):
        raise ValueError("Enter a nonnegative amount with at most two decimal places") from None


def duration_millis(minutes):
    try:
        amount = Decimal(str(minutes))
        if not amount.is_finite() or not 0 < amount <= 1440:
            raise ValueError
        millis = round_units(amount * 60000)
        if millis:
            return millis
    except (InvalidOperation, ValueError):
        pass
    raise ValueError("Time must be between one millisecond and 24 hours")


def round_units(value):
    return int(value.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def money(amount):
    return format(Decimal(amount) / 100, ".2f")


def hours(millis):
    return format(Decimal(millis) / TO_HOURS, ".4f")


def folder_path(value):
    return str(Path(required(value, "Folder")).expanduser().resolve())


def create_project(conn, name, client, kind, folder):
    name = required(name, "Project")
    if client is None or not str(client).strip():
        if kind == "billable":
            raise ValueError("Billable projects need a client")
        client = self_client(conn)
    client = required(client, "Client")
    conn.execute(
        "INSERT OR IGNORE INTO clients SELECT client FROM projects WHERE name = ? AND client IS NOT NULL",
        (name,),
    )
    if client is not None:
        conn.execute("INSERT OR IGNORE INTO clients VALUES (?)", (client,))
    conn.execute(
        "INSERT INTO projects VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET "
        "client=excluded.client, kind=excluded.kind", (name, client, kind),
    )
    if folder:
        map_folder(conn, name, folder)


def client_list(conn):
    rows = conn.execute(
        "SELECT name FROM (SELECT name FROM clients UNION SELECT client FROM projects WHERE client IS NOT NULL) "
        "ORDER BY name COLLATE NOCASE, name"
    )
    return [row["name"] for row in rows]


def save_client(conn, name, previous=None):
    name = required(name, "Client name")
    conn.execute("BEGIN IMMEDIATE")
    existing = client_list(conn)
    if previous is not None and previous not in existing:
        raise ValueError("This client changed since it was loaded. Reload and try again.")
    if name != previous and name in existing:
        raise ValueError("A client with this name already exists")
    conn.execute("INSERT OR IGNORE INTO clients VALUES (?)", (name,))
    if previous is not None and name != previous:
        conn.execute("UPDATE projects SET client = ? WHERE client = ?", (name, previous))
        conn.execute("UPDATE chrome_profile_clients SET client = ? WHERE client = ?", (name, previous))
        conn.execute("UPDATE focus_clients SET client = ? WHERE client = ?", (name, previous))
        conn.execute("DELETE FROM clients WHERE name = ?", (previous,))
        conn.execute("UPDATE billing_terms SET name = ? WHERE scope = 'client' AND name = ?", (name, previous))
        conn.execute("UPDATE appearance SET name = ? WHERE scope = 'client' AND name = ?", (name, previous))
        if previous == self_client(conn):
            set_setting(conn, "self_client", name)


def get_project(conn, name):
    row = conn.execute("SELECT * FROM projects WHERE name = ?", (name,)).fetchone()
    if row is None:
        raise ValueError(f"Unknown project: {name}")
    return row


def map_folder(conn, project, folder):
    get_project(conn, project)
    conn.execute("INSERT OR REPLACE INTO folders VALUES (?, ?)", (folder_path(folder), project))


def unmap_folder(conn, project, folder):
    change = conn.execute("DELETE FROM folders WHERE path = ? AND project = ?", (folder_path(folder), project))
    if not change.rowcount:
        raise ValueError("This folder is not mapped to the project")


ICON_TYPES = {b"\x89PNG\r\n\x1a\n": ".png", b"\xff\xd8\xff": ".jpg"}
ICON_LIMIT = 1024 * 1024


def set_appearance(conn, scope, name, icons_dir, color=None, icon=None):
    """Set a project's colour or a client's icon. None leaves a field as is; an empty string clears it.

    The icon is copied into the ledger's own folder, named by its content, so the original file can move.
    """
    if scope == "project":
        get_project(conn, name)
        if icon is not None:
            raise ValueError("Icons belong to clients")
    elif name not in client_list(conn):
        raise ValueError(f"Unknown client: {name}")
    row = conn.execute("SELECT color, icon FROM appearance WHERE scope = ? AND name = ?", (scope, name)).fetchone()
    current_color, current_icon = (row["color"], row["icon"]) if row else (None, None)
    if color is not None:
        color = color.strip()
        if color and not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
            raise ValueError("Use a colour like #3478F6")
        current_color = color.upper() or None
    if icon is not None:
        if icon.strip():
            data = Path(icon).expanduser().read_bytes()[:ICON_LIMIT + 1]
            if len(data) > ICON_LIMIT:
                raise ValueError("Use an icon image under 1 MB")
            suffix = next((ext for magic, ext in ICON_TYPES.items() if data.startswith(magic)), None)
            if suffix is None:
                raise ValueError("Use a PNG or JPEG image for the icon")
            import hashlib
            folder = Path(icons_dir)
            folder.mkdir(mode=0o700, parents=True, exist_ok=True)
            target = folder / (hashlib.sha256(data).hexdigest()[:20] + suffix)
            target.write_bytes(data)
            current_icon = str(target)
        else:
            current_icon = None
    if current_color is None and current_icon is None:
        conn.execute("DELETE FROM appearance WHERE scope = ? AND name = ?", (scope, name))
    else:
        conn.execute("INSERT OR REPLACE INTO appearance VALUES (?, ?, ?, ?)", (scope, name, current_color, current_icon))


def appearance_list(conn):
    # A list rather than an object keyed by name: the app converts keys from snake case.
    return [dict(row) for row in conn.execute("SELECT * FROM appearance ORDER BY scope, name")]


def project_list(conn):
    projects = {}
    for row in conn.execute("SELECT * FROM projects ORDER BY name"):
        projects[row["name"]] = dict(row, folders=[])
    for row in conn.execute("SELECT * FROM folders ORDER BY path"):
        projects[row["project"]]["folders"].append(row["path"])
    rows = conn.execute(
        "SELECT link.project, link.repo, link.refreshed_at, route.number FROM github_projects AS link "
        "LEFT JOIN github_pr_routes AS route ON route.project = link.project "
        "AND route.repo = link.repo ORDER BY link.project, route.number"
    )
    for row in rows:
        projects[row["project"]]["github_repo"] = row["repo"]
        projects[row["project"]]["github_refreshed_at"] = row["refreshed_at"]
        routes = projects[row["project"]].setdefault("github_routed_prs", [])
        if row["number"] is not None:
            routes.append(row["number"])
    return list(projects.values())


def model_rate(conn, provider, model, rates):
    conn.execute(
        "INSERT OR REPLACE INTO model_rates VALUES (?, ?, ?, ?, ?, ?)",
        (provider, required(model, "Model"), *(cents(rate) for rate in rates)),
    )


def subscriptions(conn):
    items = [{"name": row["name"], "monthly": money(row["monthly_cents"]), "provider": row["provider"]}
             for row in conn.execute("SELECT * FROM subscriptions ORDER BY name COLLATE NOCASE, name")]
    return {"plans": items, "monthly_total": format(sum((Decimal(item["monthly"]) for item in items), Decimal(0)), ".2f")}


def set_subscription(conn, name, monthly=None, provider=None, new_only=False):
    name = required(name, "Plan name")
    if monthly is None:
        conn.execute("DELETE FROM subscriptions WHERE name = ?", (name,))
    else:
        amount = cents(monthly)
        if new_only:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM subscriptions WHERE name = ?", (name,)).fetchone():
                raise ValueError("A subscription with this name already exists")
        if provider is None:
            conn.execute(
                "INSERT INTO subscriptions (name, monthly_cents) VALUES (?, ?) "
                "ON CONFLICT(name) DO UPDATE SET monthly_cents = excluded.monthly_cents", (name, amount),
            )
        else:
            conn.execute("INSERT OR REPLACE INTO subscriptions (name, monthly_cents, provider) VALUES (?, ?, ?)",
                         (name, amount, required(provider, "Provider") if provider.strip() else None))


def add_entry(conn, entry, refresh=False):
    base = dict(millis=0, input=0, cached=0, cache_write=0, output=0, reimbursable=0,
                cache_write_1h=0, reasoning=0, web_searches=0, replica=0)
    values = (entry.get(field, base.get(field)) for field in ENTRY_FIELDS)
    placeholders = ", ".join("?" for _ in ENTRY_FIELDS)
    updates = ", ".join(
        f"{field}=excluded.{field}" for field in ENTRY_FIELDS if field not in ("id", "project")
    )
    conflict = f"DO UPDATE SET {updates}" if refresh else "DO NOTHING"
    conn.execute(
        f"INSERT INTO entries ({', '.join(ENTRY_FIELDS)}) VALUES ({placeholders}) ON CONFLICT(id) {conflict}",
        tuple(values),
    )


def assign(conn, entry_id, project):
    if project is not None:
        get_project(conn, project)
    change = conn.execute(
        "UPDATE entries SET project = ? WHERE id = ? AND provider IS NOT NULL",
        (project, required(entry_id, "Entry ID")),
    )
    if not change.rowcount:
        raise ValueError(f"Unknown imported entry: {entry_id}")


def task_from_branch(branch):
    if not branch:
        return None
    keys = set(re.findall(r"(?i)(?<![A-Z0-9])[A-Z][A-Z0-9]{1,15}-[0-9]+(?![0-9])", branch.upper()))
    return next(iter(keys)) if len(keys) == 1 else None


def toggl_intervals(conn, start, end):
    return conn.execute(
        "SELECT 'toggl:' || account || ':' || id AS id, project, "
        "max(started_at, ?) AS started_at, min(ended_at, ?) AS ended_at "
        "FROM toggl_time WHERE ended_at > ? AND started_at < ?",
        (start, end, start, end),
    )


def entries_for(conn, start, end):
    projects = {row["name"]: dict(row) for row in conn.execute("SELECT * FROM projects")}
    folders = conn.execute("SELECT * FROM folders ORDER BY length(path) DESC, path").fetchall()
    records = (dict(row) for row in conn.execute("SELECT * FROM entries WHERE at >= ? AND at < ?", (start, end)))
    routes = github.routes(conn)
    by_branch = github.links_by_branch(conn) if routes else {}
    worktrees = {}
    approved = conn.execute(
        "SELECT focus_blocks.*, focus_matches.tag, focus_github.repo, focus_github.number "
        "FROM focus_blocks LEFT JOIN focus_matches ON focus_matches.block_id = focus_blocks.id "
        "LEFT JOIN focus_github ON focus_github.block_id = focus_blocks.id "
        "WHERE project IS NOT NULL AND closed = 1 "
        "AND ignored = 0 AND ended_at > ? AND started_at < ?",
        (start, end),
    )
    automatic = (
        dict.fromkeys(ENTRY_FIELDS) | {
            "id": "focus:" + row["id"], "kind": "human", "at": max(row["started_at"], start),
            "project": row["project"], "label": row["app_name"], "input": 0, "cached": 0,
            "cache_write": 0, "output": 0, "reimbursable": 0, "time_source": "automatic",
            "tag": row["tag"],
            "github_repo": row["repo"], "github_pr": row["number"],
            "millis": min(row["ended_at"], end) - max(row["started_at"], start),
        }
        for row in approved
    )
    toggl = (
        dict.fromkeys(ENTRY_FIELDS) | {
            "id": row["id"], "kind": "human", "at": row["started_at"],
            "project": row["project"], "label": "Toggl Track", "input": 0, "cached": 0,
            "cache_write": 0, "output": 0, "reimbursable": 0, "time_source": "toggl",
            "millis": row["ended_at"] - row["started_at"],
        }
        for row in toggl_intervals(conn, start, end)
    )
    for entry in sorted((*records, *automatic, *toggl), key=lambda row: (row["at"], row["id"])):
        name = entry["project"]
        folder = entry["folder"]
        folder_project = None
        if folder:
            for mapping in folders:
                root = mapping["path"]
                if folder == root or folder.startswith(root.rstrip(os.sep) + os.sep):
                    folder_project = mapping["project"]
                    break
        if routes and entry["provider"]:
            if folder and folder not in worktrees:
                worktrees[folder] = github.worktree_repos(folder)
            repo, pr = github.agent_context(routes, by_branch, worktrees.get(folder, ()),
                                           name or folder_project, entry["branch"])
            if repo:
                route = routes[repo]
                number = pr["number"] if pr else None
                name = name or route["pull_requests"].get(number) or folder_project or route["project"]
                entry.update(github_repo=repo, github_pr=number, pull_request=pr)
        name = name or folder_project
        entry["project"] = name
        project = projects.get(name, {})
        entry["client"] = project.get("client")
        entry["project_kind"] = project.get("kind")
        yield entry
