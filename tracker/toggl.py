"""Read-only Toggl Track imports for the local ledger."""

import base64
import json
import re
from datetime import date, datetime, timedelta, timezone
from http.client import HTTPException
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, build_opener

from . import store
from .openrouter import NoRedirect, endpoint

BASE_URL = "https://api.track.toggl.com/api/v9"
REPORTS_URL = "https://api.track.toggl.com/reports/api/v3"
MAX_RESPONSE = 8 * 1024 * 1024
ENTRY_LIMIT = 1000


class HistoryDateLimit(ValueError):
    pass


def request_json(key, url, payload=None):
    key = key.strip()
    if not re.fullmatch(r"[!-~]{1,512}", key) or ":" in key:
        raise ValueError("Enter a Toggl Track API token.")
    auth = base64.b64encode((key + ":api_token").encode("ascii")).decode("ascii")
    headers = {"Authorization": "Basic " + auth, "Accept": "application/json"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    request = Request(endpoint(url), data, headers)
    try:
        with build_opener(NoRedirect()).open(request, timeout=12) as response:
            body = response.read(MAX_RESPONSE + 1)
            response_headers = response.headers
    except HTTPError as error:
        with error:
            if error.code == 400 and url.startswith(BASE_URL + "/me/time_entries?"):
                if re.search(rb"start_date must not be earlier than \d{4}-\d{2}-\d{2}", error.read(1024)):
                    raise HistoryDateLimit("The requested dates require a Toggl detailed report.") from None
        if error.code == 403 and url.startswith(REPORTS_URL + "/"):
            raise ValueError("Toggl Track denied access to detailed reports for this workspace.") from None
        if error.code in (401, 403):
            raise ValueError("Toggl Track denied access. Check the API token in your Toggl Track profile.") from None
        raise ValueError(f"Toggl Track request failed (HTTP {error.code}).") from None
    except (OSError, HTTPException):
        raise ValueError("Could not reach Toggl Track. Check your connection and try again.") from None
    if len(body) > MAX_RESPONSE:
        raise ValueError("Toggl Track response exceeded the size limit.")
    try:
        return json.loads(body), response_headers
    except ValueError:
        raise ValueError("Toggl Track returned an unreadable response.") from None

def fetch(key, path, params):
    suffix = "?" + urlencode(params) if params else ""
    rows, _ = request_json(key, BASE_URL + path + suffix)
    return rows



def projects(key):
    rows = fetch(key, "/me/projects", {"include_archived": "true"})
    if isinstance(rows, dict):
        rows = rows.get("items")
    if not isinstance(rows, list):
        raise ValueError("Toggl Track returned an invalid project list.")
    result = []
    for row in rows:
        try:
            number, name = row["id"], row["name"]
            if type(number) is not int or not 0 < number < 2**63:
                raise ValueError
            result.append({"id": number, "name": store.required(name, "Project"),
                           "archived": row.get("active") is False,
                           "workspace_id": row.get("workspace_id") or row.get("wid")})
        except (KeyError, TypeError, ValueError):
            raise ValueError("Toggl Track returned an invalid project.") from None
    return sorted(result, key=lambda row: (row["archived"], row["name"].casefold(), row["id"]))


def account(key):
    """Verify a token and describe the account: name, email and workspaces. Nothing secret is returned."""
    me = fetch(key, "/me", None)
    spaces = fetch(key, "/me/workspaces", None)
    if not isinstance(me, dict) or not isinstance(spaces, list):
        raise ValueError("Toggl Track returned an unreadable account.")
    workspaces = [{"id": row["id"], "name": str(row.get("name") or f"Workspace {row['id']}")}
                  for row in spaces if isinstance(row, dict) and type(row.get("id")) is int]
    if not workspaces:
        raise ValueError("This Toggl Track account has no workspaces.")
    return {"name": str(me.get("fullname") or ""), "email": str(me.get("email") or ""),
            "default_workspace_id": me.get("default_workspace_id"), "workspaces": workspaces}


def link(conn, key, workspace=None):
    """Verify the token and remember who is connected and which workspace Tracker reads."""
    details = account(key)
    ids = [space["id"] for space in details["workspaces"]]
    chosen = workspace if workspace is not None else details["default_workspace_id"]
    if chosen not in ids:
        chosen = ids[0]
    details["workspace_id"] = chosen
    store.set_setting(conn, "toggl_account", json.dumps(details))
    return details


def choose_workspace(conn, workspace):
    details = linked(conn)
    if details is None:
        raise ValueError("Connect Toggl Track first.")
    if workspace not in [space["id"] for space in details["workspaces"]]:
        raise ValueError("Choose one of this account's workspaces.")
    details["workspace_id"] = workspace
    store.set_setting(conn, "toggl_account", json.dumps(details))
    return details


def linked(conn):
    value = store.setting(conn, "toggl_account", None)
    try:
        return json.loads(value) if value else None
    except ValueError:
        return None


def unlink(conn):
    conn.execute("DELETE FROM settings WHERE key = 'toggl_account'")


def history(key, start, end):
    def utc(stamp):
        return datetime.fromtimestamp(stamp / 1000, timezone.utc).isoformat(timespec="milliseconds")

    rows = fetch(key, "/me/time_entries", {"start_date": utc(start), "end_date": utc(end)})
    if not isinstance(rows, list):
        raise ValueError("Toggl Track returned an invalid time entry list.")
    if len(rows) >= ENTRY_LIMIT:
        if end - start <= 60_000:
            raise ValueError("Toggl Track returned too many entries in one minute to safely import.")
        middle = (start + end) // 2
        yield from history(key, start, middle)
        yield from history(key, middle, end)
    else:
        yield from rows


def report_history(key, source, account, first, last):
    workspace = next((item["workspace_id"] for item in projects(key) if item["id"] == source), None)
    if type(workspace) is not int or not 0 < workspace < 2**63:
        raise ValueError("Toggl Track could not find the workspace for this project.")
    url = f"{REPORTS_URL}/workspace/{workspace}/search/time_entries"
    # Report dates use the Toggl profile's timezone. The ledger window is enforced on each timestamp below.
    payload = {"start_date": (first - timedelta(days=2)).isoformat(),
               "end_date": (last + timedelta(days=1)).isoformat(),
               "user_ids": [account], "project_ids": [source], "grouped": False,
               "hide_amounts": True, "page_size": 100}
    cursor_fields = {"X-Next-ID": "first_id", "X-Next-Row-Number": "first_row_number",
                     "X-Next-Timestamp": "first_timestamp"}
    seen = set()
    while True:
        rows, headers = request_json(key, url, payload)
        if not isinstance(rows, list):
            raise ValueError("Toggl Track returned an invalid detailed report.")
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError("Toggl Track returned an invalid detailed report row.")
            if row.get("user_id") != account or row.get("project_id") != source:
                continue
            items = row.get("time_entries")
            if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
                raise ValueError("Toggl Track returned invalid detailed report entries.")
            for item in items:
                yield dict(item, project_id=source, duration=item.get("seconds"))
        try:
            cursor = {field: int(headers[header]) for header, field in cursor_fields.items() if header in headers}
        except ValueError:
            raise ValueError("Toggl Track returned an invalid detailed report page cursor.") from None
        if not cursor:
            return
        position = tuple(cursor.items())
        if position in seen:
            raise ValueError("Toggl Track returned a repeated detailed report page cursor.")
        seen.add(position)
        for field in cursor_fields.values():
            payload.pop(field, None)
        payload.update(cursor)


def import_time(conn, key, source, project, start, end):
    store.get_project(conn, project)
    first, last, after, before = store.day_range(conn, start, end)
    first, last = date.fromisoformat(first), date.fromisoformat(last)
    if (last - first).days > 31:
        raise ValueError("Choose a Toggl date range of at most 31 days.")
    if not 0 < source < 2**63:
        raise ValueError("Choose a Toggl Track project.")
    profile = fetch(key, "/me", {"with_related_data": "false"})
    account = profile.get("id") if isinstance(profile, dict) else None
    if type(account) is not int or not 0 < account < 2**63:
        raise ValueError("Toggl Track returned an invalid account.")
    try:
        rows = list(history(key, after, before))
    except HistoryDateLimit:
        rows = report_history(key, source, account, first, last)
    entries = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Toggl Track returned an invalid time entry.")
        if (row.get("project_id") or row.get("pid")) != source or row.get("server_deleted_at"):
            continue
        duration = row.get("duration")
        if type(duration) is int and duration < 0:
            continue
        number = row.get("id")
        began = store.parse_at(row.get("start"))
        if row.get("stop") is None:
            if began is None or type(duration) is not int or duration >= 2**31:
                raise ValueError("Toggl Track returned an invalid time entry.")
            stopped = began + duration * 1000
        else:
            stopped = store.parse_at(row["stop"])
        if type(number) is not int or not 0 < number < 2**63 or began is None or stopped is None or stopped < began:
            raise ValueError("Toggl Track returned an invalid time entry.")
        if after <= began < before and stopped > began:
            entries[number] = (number, account, source, project, began, stopped)
    conn.execute("BEGIN IMMEDIATE")
    conn.execute("DELETE FROM toggl_time WHERE account = ? AND toggl_project = ? "
                 "AND started_at >= ? AND started_at < ?", (account, source, after, before))
    conn.executemany(
        "INSERT OR REPLACE INTO toggl_time VALUES (?, ?, ?, ?, ?, ?)",
        entries.values(),
    )
    return {"entries": len(entries)}
