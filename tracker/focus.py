import json
from datetime import date, datetime, time, timedelta
import re
from urllib.parse import urlsplit, urlunsplit
from uuid import UUID, uuid4

from . import billing, github, store
from .importers import TOKEN_FIELDS


def record(conn, blocks):
    if not isinstance(blocks, list) or len(blocks) > 1000:
        raise ValueError("Expected up to 1,000 activity blocks")
    for block in blocks:
        if not isinstance(block, dict):
            raise ValueError("Invalid activity block")
        key = str(UUID(store.required(block.get("id"), "Block ID")))
        app_id = store.required(block.get("app_id"), "App identifier")
        app_name = store.required(block.get("app_name"), "App name")
        start, end, closed = (block.get(field) for field in ("started_at", "ended_at", "closed"))
        if (type(start) is not int or type(end) is not int or type(closed) is not bool
                or not 0 <= start < end <= 253402300799999 or end - start > 7 * 86400000):
            raise ValueError("Invalid activity interval")
        ignored = block.get("ignored")
        if ignored is None:
            ignored = False
        if type(ignored) is not bool:
            raise ValueError("ignored must be true or false")
        match = None if ignored else block.get("match")
        context = None if ignored else block.get("github")
        client = None if ignored else block.get("client")
        if client is not None and not isinstance(client, str):
            raise ValueError("client must be a string")
        repo = number = None
        if context is not None:
            if not isinstance(context, dict):
                raise ValueError("Invalid GitHub activity context")
            repo = github.repo_name(store.required(context.get("repo"), "GitHub repository"))
            number = context.get("number")
            if number is not None and (type(number) is not int or not 0 < number <= 2147483647):
                raise ValueError("Invalid GitHub pull request number")
        project = match_details = None
        if match is not None:
            if not isinstance(match, dict):
                raise ValueError("Invalid rule match")
            project = store.required(match.get("project"), "Project")
            if match.get("field") == "github" and repo:
                field, keyword, tag = "github", f"{repo}#{number}" if number else repo, None
            else:
                field, keyword, _, tag = rule_values(match.get("field"), match.get("keyword"), None, match.get("tag"))
            match_details = (key, field, keyword, tag)
        changed = conn.execute(
            "INSERT INTO focus_blocks (id, app_id, app_name, started_at, ended_at, closed, project, ignored) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
            "ended_at = max(focus_blocks.ended_at, excluded.ended_at), closed = excluded.closed "
            "WHERE focus_blocks.closed = 0 AND focus_blocks.ignored = excluded.ignored "
            "AND focus_blocks.started_at = excluded.started_at AND focus_blocks.app_id = excluded.app_id "
            "AND focus_blocks.project IS excluded.project",
            (key, app_id, app_name, start, end, int(closed), project, int(ignored)),
        )
        if changed.rowcount and match_details:
            conn.execute("INSERT OR IGNORE INTO focus_matches VALUES (?, ?, ?, ?)", match_details)
        if changed.rowcount and repo:
            conn.execute("INSERT OR IGNORE INTO focus_github VALUES (?, ?, ?)", (key, repo, number))
        if changed.rowcount and client is not None:
            conn.execute("INSERT OR IGNORE INTO focus_clients SELECT ?, name FROM clients WHERE name = ?", (key, client))


def config(conn):
    rules = conn.execute("SELECT * FROM focus_rules ORDER BY field, keyword COLLATE NOCASE, id")
    chrome_clients = dict(conn.execute("SELECT profile_id, client FROM chrome_profile_clients ORDER BY profile_id"))
    return {"enabled": store.setting(conn, "focus_enabled", "0") == "1",
            "rules": [dict(row, ignore=True) if row["project"] is None else dict(row) for row in rules],
            "auto_rules": auto_rules(conn),
            "auto_rules_off": sorted(auto_rules_off(conn)), "github_routes": github.routes(conn),
            "chrome_profile_clients": chrome_clients}


def set_chrome_profile_client(conn, profile_id, client):
    if not re.fullmatch(r"Default|Profile (?:0|[1-9][0-9]{0,9})", profile_id):
        raise ValueError("Choose an ID from the Chrome profiles list")
    if client is None:
        conn.execute("DELETE FROM chrome_profile_clients WHERE profile_id = ?", (profile_id,))
        return
    if client not in store.client_list(conn):
        raise ValueError(f"Unknown client: {client}")
    conn.execute("INSERT OR IGNORE INTO clients VALUES (?)", (client,))
    conn.execute(
        "INSERT INTO chrome_profile_clients VALUES (?, ?) ON CONFLICT(profile_id) DO UPDATE SET client = excluded.client",
        (profile_id, client),
    )


AUTO_MIN_LENGTH = 3
AUTO_MAX_LENGTH = 150  # the limit rule_values() accepts for window keywords


def auto_rules_off(conn):
    try:
        names = json.loads(store.setting(conn, "auto_rules_off", "[]"))
    except ValueError:
        return set()
    return {name for name in names if isinstance(name, str)} if isinstance(names, list) else set()


def set_auto_rules(conn, project, enabled):
    if not conn.execute("SELECT 1 FROM projects WHERE name = ?", (project,)).fetchone():
        raise ValueError(f"Unknown project: {project}")
    names = auto_rules_off(conn)
    (names.discard if enabled else names.add)(project)
    store.set_setting(conn, "auto_rules_off", json.dumps(sorted(names)))


def auto_rules(conn):
    """Window-title rules Tracker makes by itself: a project's name routes to that project, and a client's
    name routes to its project when the client has only one. Names shared by several projects are left out."""
    projects = conn.execute("SELECT name, client FROM projects ORDER BY name COLLATE NOCASE").fetchall()
    off = auto_rules_off(conn)
    me = store.self_client(conn).casefold()
    by_client = {}
    for row in projects:
        if row["client"]:
            by_client.setdefault(row["client"], []).append(row["name"])
    candidates = {}
    for row in projects:
        candidates.setdefault(row["name"].strip().casefold(), set()).add((row["name"], row["name"], "project"))
    for client, names in by_client.items():
        if len(names) == 1 and client.strip().casefold() != me:
            candidates.setdefault(client.strip().casefold(), set()).add((client.strip(), names[0], "client"))
    result = []
    for key in sorted(candidates):
        targets = candidates[key]
        if not AUTO_MIN_LENGTH <= len(key) <= AUTO_MAX_LENGTH or len({project for _, project, _ in targets}) != 1:
            continue
        keyword, project, source = min(targets, key=lambda item: item[2] != "project")
        if project in off:
            continue
        result.append({"id": f"auto:{source}:{keyword}", "field": "window", "keyword": keyword, "app_scope": None,
                       "tag": None, "project": project, "chrome_profile": None, "automatic": source})
    return result


def rule_values(field, keyword, app_scope, tag):
    if field not in ("app", "window", "domain", "url"):
        raise ValueError("Choose an app, window, domain, or URL rule")
    keyword = store.required(keyword, "Keyword")
    if any(value is not None and not isinstance(value, str) for value in (app_scope, tag)):
        raise ValueError("App scope and tag must be strings")
    app_scope = (app_scope or "").strip() or None
    tag = (tag or "").strip() or None
    if len(keyword) > (512 if field == "url" else 150) or len(app_scope or "") > 150 or len(tag or "") > 150:
        raise ValueError("Use up to 512 characters for a URL and 150 for other rule fields")
    if field in ("domain", "url"):
        keyword = browser_rule(field, keyword)
    return field, keyword, None if field == "app" else app_scope, tag


def browser_rule(field, keyword):
    # An address typed without a scheme ("github.com/org") is an HTTPS URL, as the rule editor reads it.
    if field == "url" and "://" not in keyword:
        keyword = "https://" + keyword
    if any(c.isspace() or ord(c) < 32 for c in keyword):
        raise ValueError("A domain or URL cannot contain whitespace")
    if "#" in keyword or "?" in keyword:
        raise ValueError("Use a domain or URL path without query strings or fragments")
    try:
        address = urlsplit("//" + keyword if field == "domain" else keyword)
        host = (address.hostname or "").rstrip(".").encode("idna").decode("ascii").lower()
        port = address.port
    except (UnicodeError, ValueError):
        raise ValueError("Enter a valid domain or HTTP(S) URL") from None
    if (not host or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part)
                        for part in host.split(".")) or address.username is not None):
        raise ValueError("Enter a valid hostname without credentials")
    if field == "domain":
        if address.path or port is not None or ":" in address.netloc:
            raise ValueError("Use only the domain, for example app.example.com")
        return host
    scheme = address.scheme.lower()
    if scheme not in ("http", "https"):
        raise ValueError("Start the URL with https:// or http://")
    default_port = 443 if scheme == "https" else 80
    origin = f"{host}:{port}" if port is not None and port != default_port else host
    return urlunsplit((scheme, origin, address.path.rstrip("/") or "/", "", ""))


def save_rule(conn, project, field, keyword, app_scope=None, tag=None, key=None, chrome_profile=None, app_id=None):
    if project is not None:
        store.get_project(conn, project)
    else:
        tag = None
    field, keyword, app_scope, tag = rule_values(field, keyword, app_scope, tag)
    if app_id is not None:
        app_id = store.required(app_id, "App identifier")
        if field not in ("app", "window") or len(app_id) > 512:
            raise ValueError("Use an app or window rule with a valid app identifier")
    if chrome_profile is not None:
        if not isinstance(chrome_profile, str) or not re.fullmatch(r"[A-Za-z0-9 _-]{1,40}", chrome_profile.strip()):
            raise ValueError("Use up to 40 letters, numbers, spaces, hyphens, or underscores for the Chrome profile")
        if field not in ("domain", "url"):
            raise ValueError("Choose a domain or URL rule to use a Chrome profile")
        chrome_profile = chrome_profile.strip()
    if key is None:
        conn.execute("INSERT INTO focus_rules (id, field, keyword, app_scope, tag, project, chrome_profile, app_id) "
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                     (str(uuid4()), field, keyword, app_scope, tag, project, chrome_profile, app_id))
    else:
        changed = conn.execute(
            "UPDATE focus_rules SET field = ?, keyword = ?, app_scope = ?, tag = ?, project = ?, chrome_profile = ?, app_id = ? "
            "WHERE id = ?",
            (field, keyword, app_scope, tag, project, chrome_profile, app_id, key),
        )
        if not changed.rowcount:
            raise ValueError("This rule no longer exists")


def close_interrupted(conn):
    # The Mac recorder takes an exclusive lease before recovering interrupted blocks.
    conn.execute("UPDATE focus_blocks SET closed = 1 WHERE closed = 0")


def timeline_blocks(conn, since, until):
    rows = conn.execute(
        "SELECT id, app_id, app_name, max(started_at, ?) AS started_at, "
        "min(ended_at, ?) AS ended_at, closed, project, ignored, keyword, tag, "
        "CASE WHEN ignored THEN NULL WHEN project IS NOT NULL THEN projects.client ELSE focus_clients.client END AS client, "
        "focus_github.repo AS github_repo, focus_github.number AS github_pr FROM focus_blocks "
        "LEFT JOIN focus_matches ON focus_matches.block_id = focus_blocks.id "
        "LEFT JOIN focus_github ON focus_github.block_id = focus_blocks.id "
        "LEFT JOIN focus_clients ON focus_clients.block_id = focus_blocks.id "
        "LEFT JOIN projects ON projects.name = focus_blocks.project "
        "WHERE ended_at > ? AND started_at < ?",
        (since, until, since, until),
    )
    blocks = [dict(row) | {"closed": bool(row["closed"]), "ignored": bool(row["ignored"]),
                           "time_source": "automatic"} for row in rows]
    for interval in store.toggl_intervals(conn, since, until):
        blocks.append(dict(interval) | {
            "app_id": None, "app_name": "Toggl Track", "closed": True, "ignored": False,
            "keyword": None, "tag": None, "github_repo": None, "github_pr": None,
            "time_source": "toggl",
        })
    blocks.sort(key=lambda block: (-block["started_at"], block["id"]))
    return blocks


def midnight(day, zone):
    return int(datetime.combine(day, time.min, zone).timestamp() * 1000)


def timeline(conn, day=None, week=False):
    zone_name = store.setting(conn, "timezone", "UTC")
    zone = store.zone(zone_name)
    day = date.fromisoformat(day) if day else datetime.now(zone).date()
    if week:
        monday = day - timedelta(days=day.weekday())
        dates = [monday + timedelta(days=offset) for offset in range(8)]
        edges = [midnight(value, zone) for value in dates]
        blocks = timeline_blocks(conn, edges[0], edges[-1])
        runs = conn.execute("SELECT at, millis FROM entries WHERE kind = 'runtime' AND at >= ? AND at < ?",
                            (edges[0], edges[-1])).fetchall()
        days = []
        for value, start, end in zip(dates, edges, edges[1:]):
            clipped = [block | {"started_at": max(start, block["started_at"]),
                                "ended_at": min(end, block["ended_at"])}
                       for block in blocks if block["ended_at"] > start and block["started_at"] < end]
            clipped.sort(key=lambda block: (-block["started_at"], block["id"]))
            agent_millis = sum(run["millis"] or 0 for run in runs if start <= run["at"] < end)
            days.append({"day": value.isoformat(), "day_start": start, "day_end": end,
                         "blocks": clipped, "agents": [], "agent_runtime_millis": agent_millis})
        return {"timezone": zone_name, "days": days}

    since, until = midnight(day, zone), midnight(day + timedelta(days=1), zone)
    blocks = timeline_blocks(conn, since, until)
    agents = {}
    entries = list(store.entries_for(conn, since, until))
    for entry in entries:
        if entry["kind"] not in ("runtime", "usage"):
            continue
        key = (entry["provider"], entry["project"], entry["folder"] if entry["project"] is None else None)
        row = agents.setdefault(key, {
            "provider": key[0], "project": key[1], "folder": key[2], "client": entry["client"],
            "tokens": 0, "runtime_millis": None, "runtime_method": None,
        })
        if entry["kind"] == "usage":
            row["tokens"] += sum(entry[field] for field in TOKEN_FIELDS)
        else:
            row["runtime_millis"] = (row["runtime_millis"] or 0) + entry["millis"]
            row["runtime_method"] = entry["label"]
    return {
        "day": day.isoformat(), "timezone": zone_name, "day_start": since, "day_end": until,
        "blocks": blocks, "agents": list(agents.values()),
        "agent_threads": agent_threads(entries),
        "billing": billing.day_spans(conn, entries),
    }


# Runs of one thread closer together than this are drawn as one block. It matches LANE_CLEARANCE,
# because short runs are drawn taller than they last and would otherwise cover each other.
THREAD_MERGE_GAP = 20 * 60 * 1000
# Requests without a recorded duration still get a visible sliver on the calendar.
MIN_RUN = 60 * 1000
# Short runs are drawn taller than their duration, so lanes keep this much clearance between threads.
LANE_CLEARANCE = 20 * 60 * 1000


def agent_threads(entries):
    """Group agent runs by thread (session) and give overlapping threads separate lanes per provider.

    Each thread keeps its runs as start/end spans with the tokens that fell inside them,
    so the day view can draw one column per thread that was active at the same time.
    """
    threads = {}
    usage = {}
    for entry in entries:
        if entry["kind"] not in ("runtime", "usage") or not entry["provider"]:
            continue
        key = (entry["provider"], entry["session"] or entry["folder"] or entry["id"])
        thread = threads.setdefault(key, {
            "id": f"{key[0]}:{key[1]}", "provider": key[0], "session": entry["session"],
            "project": entry["project"], "client": entry["client"], "folder": entry["folder"],
            "branch": entry["branch"], "spans": [],
        })
        thread["project"] = thread["project"] or entry["project"]
        thread["client"] = thread["client"] or entry["client"]
        thread["branch"] = thread["branch"] or entry["branch"]
        if entry["kind"] == "runtime" and entry["millis"]:
            thread["spans"].append([entry["at"], entry["at"] + entry["millis"]])
        elif entry["kind"] == "usage":
            usage.setdefault(key, []).append(
                (entry["at"], sum(entry[field] or 0 for field in TOKEN_FIELDS)))

    rows = []
    for key, thread in threads.items():
        points = usage.get(key, [])
        spans = thread.pop("spans") or [[at, at + MIN_RUN] for at, _ in points]
        busy = []  # Overlapping spans counted once, so runtime excludes the gaps that merging bridges.
        for start, end in sorted(spans):
            if busy and start <= busy[-1][1]:
                busy[-1][1] = max(busy[-1][1], end)
            else:
                busy.append([start, end])
        merged = []
        for start, end in sorted(spans):
            if merged and start - merged[-1]["ended_at"] <= THREAD_MERGE_GAP:
                merged[-1]["ended_at"] = max(merged[-1]["ended_at"], end)
            else:
                merged.append({"started_at": start, "ended_at": max(end, start + MIN_RUN), "tokens": 0})
        for at, tokens in points:
            # Usage can be logged just after its turn ends; credit it to the nearest earlier run.
            target = next((run for run in reversed(merged) if run["started_at"] <= at), merged[0] if merged else None)
            if target:
                target["tokens"] += tokens
        if not merged:
            continue
        thread["runs"] = merged
        thread["started_at"] = merged[0]["started_at"]
        thread["ended_at"] = max(run["ended_at"] for run in merged)
        thread["tokens"] = sum(run["tokens"] for run in merged)
        thread["runtime_millis"] = sum(end - start for start, end in busy)
        rows.append(thread)

    rows.sort(key=lambda row: (row["provider"], row["started_at"], row["id"]))
    lanes = {}

    def overlaps(runs, taken):
        return any(run["started_at"] < end + LANE_CLEARANCE and start < run["ended_at"] + LANE_CLEARANCE
                   for run in runs for start, end in taken)

    for row in rows:
        # A thread shares a lane with others as long as none of its runs overlap theirs,
        # so a thread that idles for hours does not hold a column to itself.
        provider_lanes = lanes.setdefault(row["provider"], [])
        lane = next((index for index, taken in enumerate(provider_lanes) if not overlaps(row["runs"], taken)),
                    len(provider_lanes))
        if lane == len(provider_lanes):
            provider_lanes.append([])
        provider_lanes[lane].extend((run["started_at"], run["ended_at"]) for run in row["runs"])
        row["lane"] = lane
    return rows


def classify(conn, key, project=None, ignored=False):
    if project is not None:
        store.get_project(conn, project)
    changed = conn.execute(
        "UPDATE focus_blocks SET project = ?, ignored = ? WHERE id = ? AND closed = 1",
        (project, int(ignored), key),
    )
    if not changed.rowcount:
        raise ValueError("This activity is still being recorded or no longer exists")
    conn.execute("DELETE FROM focus_matches WHERE block_id = ?", (key,))
