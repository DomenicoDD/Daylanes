"""Run the same commands through the Python reference engine (tracker/) and the Swift engine and compare the results.

    python3 tests/parity.py build/Tracker.app/Contents/MacOS/TrackerCLI [--ledger PATH]

Each engine gets its own copy of the ledger (the real one is never written). For every command the
script compares stdout (as JSON when it is JSON), the exit status, the error message and, at the end,
every table of both copies. Generated entry ids are replaced by placeholders before comparing.
Exit status 0 means no differences.
"""
import argparse
import base64
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent

# Commands ported to Swift so far, run in order against both copies. "{folder}" is a scratch folder.
AGENTS = {"HOME": "{agents}"}

SCRIPT = [
    ["init", "--default-timezone", "Europe/Rome"],
    ["init"],
    ["project", "list"],
    ["client", "list"],
    ["subscription", "list"],
    ["project", "add", "--kind", "internal", "--", "Parity Site"],
    ["project", "add", "Parity Shop", "--kind=billable", "--client=Parity Acme", "--folder", "{folder}",
     "--github", "https://github.com/Acme/Shop.git"],
    ["project", "add", "Parity X", "--kind", "billable"],
    ["project", "add", "Parity Site", "--kind", "internal", "--new-only"],
    ["project", "map", "Parity Site", "{folder}/sub"],
    ["project", "unmap", "Parity Site", "{folder}/other"],
    ["project", "map", "Parity Site", "{folder}/link/../mapped"],  # ".." applies after the symlink
    ["project", "list"],
    ["client", "save", "Parity Acme 2", "--previous", "Parity Acme"],
    ["client", "save", "B", "--previous", "Gone"],
    ["client", "list"],
    ["appearance", "--project=Parity Shop", "--color=#3478f6"],
    ["appearance", "--project", "Parity Shop", "--color", "blue"],
    ["appearance", "--client", "Parity Acme 2", "--color", "#000000"],
    ["subscription", "set", "Parity Max", "--monthly", "100", "--provider=claude"],
    ["subscription", "set", "Parity Max", "--monthly", "1", "--new-only"],
    ["subscription", "set", "Parity Pro", "--monthly", "20.5"],
    ["subscription", "remove", "Parity Max"],
    ["model-rate", "codex", "parity-model", "--input", "1.25", "--cached", "0.125", "--cache-write", "0", "--output", "10"],
    ["model-rate", "codex", "parity-model", "--input", "1.255", "--cached", "0", "--cache-write", "0", "--output", "0"],
    ["time", "Parity Site", "--minutes", "90", "--activity", "reviewing", "--at", "2026-11-20T09:00:00"],
    ["time", "Parity Site", "--minutes", "0"],
    ["time", "Parity Site", "--minutes", "5", "--at", "2026-11-20T10:30:00+23:00"],
    ["time", "Nope", "--minutes", "5"],
    ["expense", "Parity Shop", "API credits", "--amount", "12.40", "--reimburse", "--task", "ABC-1", "--at", "2026-11-19"],
    ["expense", "Parity Shop", "Bad", "--amount", "1.001"],
    ["remove", "time:missing"],
    ["assign", "codex:missing", "--use-folder"],
    ["init", "--currency", "GBP"],
    ["focus", "config"],
    ["focus", "config", "--enabled", "on"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "domain", "--keyword", "App.Example.com."],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "url", "--keyword", "HTTPS://Example.com:443/a/b/",
     "--chrome-profile", " Work ", "--tag", "  "],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "url", "--keyword", "http://example.com:8080"],
    ["focus", "save-rule", "--project", "Parity Shop", "--field", "app", "--keyword", "Xcode", "--app-scope", "x"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "app", "--keyword", "TextEdit",
     "--app-id", "com.apple.TextEdit"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "window", "--keyword", "TextEdit",
     "--app-id", "com.apple.TextEdit"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "window", "--keyword", "Invoice", "--app-scope", "Preview"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "domain", "--keyword", "example.com/path"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "domain", "--keyword", "bad_host.com"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "domain", "--keyword", "user@example.com"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "domain", "--keyword", "café.example"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "url", "--keyword", "ftp://example.com"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "url", "--keyword", "https://example.com/?q=1"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "url", "--keyword", "https://example.com:99999/"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "app", "--keyword", "Mail", "--chrome-profile", "Work"],
    ["focus", "save-rule", "--project", "Parity Site", "--field", "app", "--keyword", "Mail", "--id", "missing"],
    ["focus", "save-rule", "--project", "Nope", "--field", "app", "--keyword", "Mail"],
    ["focus", "delete-rule", "missing"],
    ["focus", "auto-rules", "Parity Site", "--state", "off"],
    ["focus", "auto-rules", "Parity Site", "--state", "off"],
    ["focus", "auto-rules", "Nope", "--state", "off"],
    ["focus", "config"],
    ["focus", "auto-rules", "Parity Site", "--state", "on"],
    (["focus", "record"], '[{"id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", "app_id": "com.apple.Safari", "app_name": "Safari", "started_at": 1795046400000, "ended_at": 1795047000000, "closed": false, "match": {"project": "Parity Site", "field": "domain", "keyword": "Example.com", "tag": " docs "}},\n {"id": "{2b4e28ba-2fa1-11d2-883f-0016d3cca427}", "app_id": "com.google.Chrome", "app_name": "Chrome", "started_at": 1795047000000, "ended_at": 1795048000000, "closed": true, "github": {"repo": "Acme/Shop", "number": 7}, "match": {"project": "Parity Shop", "field": "github"}},\n {"id": "3b4e28ba2fa111d2883f0016d3cca427", "app_id": "com.apple.Terminal", "app_name": "Terminal", "started_at": 1795048000000, "ended_at": 1795049000000, "closed": true}]'),
    (["focus", "record"], '[{"id": "1b4e28ba-2fa1-11d2-883f-0016d3cca427", "app_id": "com.apple.Safari", "app_name": "Safari", "started_at": 1795046400000, "ended_at": 1795047600000, "closed": true, "match": {"project": "Parity Site", "field": "domain", "keyword": "example.com", "tag": "docs"}}]'),
    (["focus", "record"], '[{"id": "nope", "app_id": "a", "app_name": "A", "started_at": 1, "ended_at": 2, "closed": true}]'),
    (["focus", "record"], '[{"id": "4b4e28ba-2fa1-11d2-883f-0016d3cca427", "app_id": "a", "app_name": "A", "started_at": 2, "ended_at": 1, "closed": true}]'),
    ["focus", "recover"],
    ["focus", "classify", "3b4e28ba-2fa1-11d2-883f-0016d3cca427", "--project", "Parity Site"],
    ["focus", "classify", "1b4e28ba-2fa1-11d2-883f-0016d3cca427", "--ignore"],
    ["focus", "classify", "missing", "--unassign"],
    ["focus", "timeline", "--week", "--day", "2026-11-18"],
    ["focus", "timeline", "--week", "--day", "2026-11-31"],
    ["github", "set", "Parity Site", "Acme/Site"],
    ["github", "route-pr", "Parity Site", "12"],
    ["github", "route-pr", "Parity Shop", "12"],
    ["github", "route-pr", "Parity Shop", "abc"],
    ["github", "route-pr", "Parity Shop", "0"],
    ["focus", "config"],
    ["github", "route-pr", "Parity Site", "12", "--remove"],
    ["github", "unlink", "Parity Site"],
    ["github", "status"],
    # Agent history: every importer reads the logs agent_fixtures() writes into a shared home folder.
    (["sync", "--opencode-db", "{agents}/missing.db"], None, AGENTS),
    (["sync", "--opencode-db", "{agents}/missing.db"], None, AGENTS),
    (["sync", "--provider", "droid", "--rescan"], None, AGENTS),
    (["sync", "--provider", "opencode", "--opencode-db", "{agents}/opencode/opencode.db"], None, AGENTS),
    (["sync", "--provider", "bogus"], None, AGENTS),
    (["sync", "--recent-days", "0"], None, AGENTS),
    (["sync", "--recent-days", "x"], None, AGENTS),
    (["import-harness", "my-agent"], '{"id": "e1", "model": "m1", "timestamp": "2026-11-20T10:00:00Z", "input": 5, '
     '"output": 2, "session": "s", "folder": "/work/app", "branch": "feat/ABC-9-x"}\n\n'
     '{"id": "e2", "model": "m1", "timestamp": 1795046400, "cached": 7}\n', None),
    (["import-harness", "my-agent"], '{"id": "e3", "model": "m1", "timestamp": "2026-11-20T10:00:00Z"}\n', None),
    (["import-harness", "Bad_Name"], "", None),
    (["import-harness", "codex"], "", None),
]


def ms(text):
    """Epoch milliseconds of an ISO timestamp with offset."""
    from datetime import datetime
    return int(datetime.fromisoformat(text).timestamp() * 1000)


CATALOG = {"fetched_at": 1795000000, "models": {
    "openai/codex-test": {"rates": {"input": "0.00000125", "cached": "0.000000125", "cache_write": None,
                                    "cache_write_1h": None, "output": "0.00001", "web_search": "0.01"},
                          "canonical": "openai/codex-test-20260101", "tiers": []},
    "anthropic/claude-test": {"rates": {"input": "0.000003", "cached": None, "cache_write": None, "cache_write_1h": None,
                                        "output": "0.000015", "web_search": None}, "canonical": None,
                              "tiers": [{"min_prompt_tokens": 200000, "rates": {
                                  "input": "0.000006", "cached": "0.0000006", "cache_write": "0.0000075",
                                  "cache_write_1h": "0.000012", "output": "0.0000225", "web_search": None}}]},
    "openai/gpt-5.5": {"rates": {"input": "0.000005", "cached": "0.0000005", "cache_write": None, "cache_write_1h": None,
                                 "output": "0.00004", "web_search": None}, "canonical": None, "tiers": []},
    "anthropic/claude-opus-4.6": {"rates": {"input": "0.000015", "cached": "0.0000015", "cache_write": "0.00001875",
                                            "cache_write_1h": "0.00003", "output": "0.000075", "web_search": None},
                                  "canonical": "anthropic/claude-4.6-opus-20260205", "tiers": []},
    "anthropic/claude-opus-4.6:batch": {"rates": {"input": "0.0000075", "output": "0.0000375"}, "canonical": None},
    "moonshotai/kimi-k2.6": {"rates": {"input": "0.0000006", "output": "0.0000025"}, "canonical": None},
    "x-ai/grok-4": {"rates": {"input": "0.000003", "cached": "0.00000075", "output": "0.000015"}, "canonical": None},
}}

ENTRY_COLUMNS = ("id", "kind", "at", "provider", "model", "session", "folder", "branch", "task", "project", "label",
                 "millis", "input", "cached", "cache_write", "output", "prompt_tokens", "cache_write_1h", "tier",
                 "recorded_usd", "web_searches")


def entry(**values):
    row = dict.fromkeys(ENTRY_COLUMNS) | {"millis": 0, "input": 0, "cached": 0, "cache_write": 0, "output": 0,
                                          "cache_write_1h": 0, "web_searches": 0} | values
    return (f"INSERT INTO entries ({', '.join(ENTRY_COLUMNS)}) VALUES ({', '.join('?' * len(ENTRY_COLUMNS))})",
            tuple(row[column] for column in ENTRY_COLUMNS))


def setting(key, value):
    return ("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, json.dumps(value) if not isinstance(value, str) else value))


# Usage, runtime and Toggl time across two DST changes (Europe 2026-10-25, US 2026-11-01) and local midnights.
SEED = [
    setting("openrouter_catalog", CATALOG),
    setting("openrouter_account_activity", {"start": "2026-10-20", "end_exclusive": "2026-11-19", "fetched_at": 1795100000,
                                            "records": [
        {"day": "2026-10-24", "model": "openai/gpt-5.5", "requests": 1200, "tokens": 3456789, "spend_usd": "12.3456"},
        {"day": "2026-11-02", "model": "anthropic/claude-opus-4.6", "requests": 7, "tokens": 9000, "spend_usd": "0.005"},
        {"day": "2026-11-18", "model": "openai/gpt-5.5", "requests": 3, "tokens": 10, "spend_usd": "0.015"}]}),
    setting("codex_rate_limits", {"observed_at": ms("2026-11-20T10:00:00+00:00"), "plan_type": "pro",
                                  "primary": {"used_percent": 42.5, "window_minutes": 300, "resets_at": 1795180000},
                                  "secondary": {"used_percent": 7, "window_minutes": 10080, "resets_in_seconds": 86400.5},
                                  "credits": {"balance": "3.50"}}),
    setting("toggl_account", {"id": 9, "name": "Parity", "workspace": 4}),
    entry(id="seed:u1", kind="usage", at=ms("2026-10-24T22:30:00+00:00"), provider="codex", model="gpt-5.5", session="s-a",
          folder="/work/app", branch="feat/CLI-42-export", input=120000, cached=50000, output=8000, tier="priority",
          prompt_tokens=170000),
    entry(id="seed:u2", kind="usage", at=ms("2026-10-25T01:10:00+00:00"), provider="claude", model="claude-test",
          session="s-b", folder="/work/app", input=150000, cached=90000, cache_write=30000, cache_write_1h=10000,
          output=4000, prompt_tokens=270000, task="ABC-1"),
    entry(id="seed:u3", kind="usage", at=ms("2026-10-25T01:20:00+00:00"), provider="claude", model="claude-test",
          session="s-b", folder="/work/app", input=10, output=5, recorded_usd="0.123456789"),
    entry(id="seed:u4", kind="usage", at=ms("2026-11-01T08:59:00+00:00"), provider="codex", model="codex-test",
          session="s-c", folder="/work/app", branch="main", input=1000, output=100, web_searches=3),
    entry(id="seed:u5", kind="usage", at=ms("2026-11-01T09:00:00+00:00"), provider="opencode", model="kimi-for-coding",
          session="s-d", project="Parity Shop", input=999999, output=12345),
    entry(id="seed:u6", kind="usage", at=ms("2026-11-02T03:00:00+00:00"), provider="my-agent", model="unpriced-model",
          session="s-e", project="Parity Shop", input=77, output=3),
    entry(id="seed:u7", kind="usage", at=ms("2026-11-20T08:00:00+00:00"), provider="codex", model="codex-auto-review",
          session="s-f", folder="/work/app", input=4000, cached=1000, output=300),
    entry(id="seed:u8", kind="usage", at=ms("2026-11-20T09:40:00+00:00"), provider="codex", model="gpt-5.5",
          session="s-f", folder="/work/app", input=6000, output=900, tier="flex"),
    entry(id="seed:r1", kind="runtime", at=ms("2026-10-24T21:50:00+00:00"), provider="codex", model="gpt-5.5",
          session="s-a", folder="/work/app", branch="feat/CLI-42-export", label="turn duration", millis=2 * 3600 * 1000),
    entry(id="seed:r2", kind="runtime", at=ms("2026-10-24T23:00:00+00:00"), provider="claude", model="claude-test",
          session="s-b", folder="/work/app", label="request window estimate", millis=45 * 60 * 1000, task="ABC-1"),
    entry(id="seed:r3", kind="runtime", at=ms("2026-11-01T06:00:00+00:00"), provider="opencode", session="s-d",
          project="Parity Shop", label="turn duration", millis=3 * 3600 * 1000),
    entry(id="seed:r4", kind="runtime", at=ms("2026-11-20T07:59:00+00:00"), provider="codex", session="s-f",
          folder="/work/app", label="turn duration", millis=25 * 60 * 1000),
    ("INSERT INTO toggl_time VALUES (?, ?, ?, ?, ?, ?)", (501, 9, 77, "Parity Shop", ms("2026-10-31T23:30:00+00:00"),
                                                          ms("2026-11-01T02:15:00+00:00"))),
    ("INSERT INTO toggl_time VALUES (?, ?, ?, ?, ?, ?)", (502, 9, 77, "Parity Shop Two", ms("2026-11-20T09:00:00+00:00"),
                                                          ms("2026-11-20T10:30:00+00:00"))),
]

PERIOD = ["--start", "2026-10-01", "--end", "2026-12-01"]
NOW = {"TRACKER_NOW": str(ms("2026-11-20T10:05:00+00:00"))}
REPORTS = [
    ["billing", "summary", *PERIOD],
    ["billing", "summary", "--start", "2026-11-01", "--end", "2026-11-08"],
    ["report", *PERIOD, "--json"],
    ["report", *PERIOD],
    ["report", "--start", "2026-10-20", "--end", "2026-11-03", "--client", "Parity Acme 2", "--json"],
    ["report", *PERIOD, "--task", "abc-1", "--json"],
    ["report", *PERIOD, "--project", "Parity Shop"],
    ["review", *PERIOD],
    ["snapshot", *PERIOD],
    ["export", *PERIOD],
    ["export", *PERIOD, "--project", "Parity Shop"],
    ["report-rows", *PERIOD],
    ["report-rows", "--start", "2026-10-20", "--end", "2026-11-10", "--client", "Parity Acme 2",
     "--project", "Parity Shop", "--project", "Parity Shop Two"],
    ["entries", *PERIOD, "--limit", "7"],
    ["entries", *PERIOD, "--unassigned"],
    ["focus", "timeline", "--day", "2026-10-25"],
    ["focus", "timeline", "--day", "2026-11-01"],
    ["focus", "timeline", "--day", "2026-11-20"],
    (["blocks", "--hours", "8784"], None, NOW),
    (["blocks", "--active"], None, NOW),
]

DESKTOP_SCRIPT = [
    ["project", "add", "--kind", "billable", "--client=Parity Beta", "--", "Parity Beta App"],
    ["project", "add", "--kind", "billable", "--client=Parity Acme 2", "--", "Parity Shop Two"],
    ["billing", "show"],
    ["billing", "set", "--client", "Parity Acme 2", "--human-rate", "90", "--agent-mode", "usage", "--markup", "1.50",
     "--cap", "50"],
    ["billing", "set", "--project", "Parity Shop Two", "--agent-mode", "hybrid", "--agent-rate", "30"],
    ["billing", "set", "--client", "Parity Beta", "--human-rate", "75.5", "--agent-mode=time", "--agent-rate", "20"],
    ["billing", "set", "--project", "Parity Beta App", "--cap", "10"],
    ["billing", "set", "--client", "Nope", "--human-rate", "1"],
    ["billing", "set", "--project", "Parity Site", "--markup", "0"],
    ["billing", "set", "--project", "Parity Site", "--agent-mode", "bogus"],
    ["billing", "set", "--client", "Parity Beta", "--project", "Parity Site"],
    ["billing", "set", "--project", "Parity Site", "--human-rate", "", "--markup", " "],
    ["billing", "exchange-rate", "abc"],
    ["billing", "exchange-rate", "0.9150"],
    ["billing", "show"],
    ["billing", "summary"],
    ("sql", SEED),
    ["project", "map", "Parity Beta App", "/work/app"],
    ["time", "Parity Shop", "--minutes", "150", "--activity", "prompting", "--task", "ABC-1", "--at", "2026-10-24T23:10:00+02:00"],
    ["time", "Parity Shop", "--minutes", "30", "--at", "2026-10-25T00:05:00+02:00"],
    ["time", "Parity Shop Two", "--minutes", "45", "--activity", "reviewing", "--at", "2026-11-20T09:15:00+00:00"],
    ["expense", "Parity Beta App", "=SUM(A1)", "--amount", "3.10", "--at", "2026-11-02"],
    *REPORTS,
    ["entries", "--limit", "0"],
    ["blocks", "--hours", "0"],
    ["focus", "timeline", "--day", "2026-02-30"],
    ["report-rows", "--start", "2026-11-01"],
    ["assign-group", "Parity Shop", "--provider", "codex", "--folder", "/work/app", "--branch", "feat/CLI-42-export",
     "--project", "Parity Beta App", "--start", "2026-10-20", "--end", "2026-10-30"],
    ["assign-group", "Parity Shop", "--provider", "codex", "--folder", "/work/app", "--start", "2026-10-20", "--end", "2026-10-30"],
    ["assign-group", "Parity Beta App", "--provider", "Bad_Name", "--start", "2026-10-20", "--end", "2026-10-30"],
    ["billing", "exchange-rate", ""],
    ["init", "--timezone", "America/Los_Angeles"],
    *REPORTS,
]


# Network sources against a local server (TRACKER_HTTP_ROOT): OpenRouter's catalog and activity, Toggl Track.
# "@models" picks the catalog response for a step; keys and tokens pick the other responses.
WEB = {**NOW, "TRACKER_HTTP_ROOT": "{http}", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
       "OPENROUTER_MANAGEMENT_KEY": ""}
IMPORT = ["--source", "42", "--project", "Parity Shop", "--start", "2026-11-02", "--end", "2026-11-09"]
NETWORK_SCRIPT = [
    (["refresh-prices", "--if-stale"], None, {**WEB, "@models": "500"}),
    (["refresh-prices"], None, {**WEB, "@models": "nodata"}),
    (["refresh-prices"], None, {**WEB, "@models": "list"}),
    (["refresh-prices"], None, {**WEB, "@models": "notlist"}),
    (["refresh-prices"], None, {**WEB, "@models": "empty"}),
    (["refresh-prices"], None, {**WEB, "@models": "big"}),
    (["refresh-prices"], None, {**WEB, "@models": "redirect"}),
    (["refresh-prices", "--if-stale"], None, {**WEB, "@models": "500"}),
    (["billing", "summary", *PERIOD], None, WEB),
    (["report", *PERIOD, "--json"], None, WEB),
    (["openrouter-sync"], None, WEB),
    (["openrouter-sync", "--key-stdin"], "bad key!", WEB),
    (["openrouter-sync", "--key-stdin"], "denied-key\n", WEB),
    (["openrouter-sync", "--key-stdin"], "error-key", WEB),
    (["openrouter-sync", "--key-stdin"], "redirect-key", WEB),
    (["openrouter-sync", "--key-stdin"], "big-key", WEB),
    (["openrouter-sync", "--key-stdin"], "junk-key", WEB),
    (["openrouter-sync", "--key-stdin"], "badrow-key", WEB),
    (["openrouter-sync"], None, {**WEB, "OPENROUTER_MANAGEMENT_KEY": " good-key "}),
    (["snapshot", "--start", "2026-10-01", "--end", "2026-11-25"], None, WEB),
    (["openrouter-sync", "--clear", "--key-stdin"], "", WEB),
    (["openrouter-sync", "--clear"], None, WEB),
    (["openrouter-sync", "--key-stdin"], "good-key", WEB),
    (["toggl", "unlink"], None, WEB),
    (["toggl", "workspace", "17"], None, WEB),
    (["toggl", "link"], "a:b", WEB),
    (["toggl", "link"], "bad-token", WEB),
    (["toggl", "link"], "tok-a\n", WEB),
    (["toggl", "link", "--workspace", "18"], "tok-a", WEB),
    (["toggl", "link", "--workspace", "99"], "tok-a", WEB),
    (["toggl", "workspace", "19"], None, WEB),
    (["toggl", "workspace", "99"], None, WEB),
    (["toggl", "workspace", "x"], None, WEB),
    (["toggl", "projects"], "tok-a", WEB),
    (["toggl", "projects"], "tok-old", WEB),
    (["toggl", "projects"], "tok-badproj", WEB),
    (["toggl", "import", *IMPORT], "tok-a", WEB),
    (["toggl", "import", *IMPORT], "tok-badentry", WEB),
    (["toggl", "import", "--source", "42", "--project", "Nope", "--start", "2026-11-02", "--end", "2026-11-09"], "tok-a", WEB),
    (["toggl", "import", "--source", "42", "--project", "Parity Shop", "--start", "2026-10-01", "--end", "2026-11-09"],
     "tok-a", WEB),
    (["toggl", "import", "--source", "0", "--project", "Parity Shop", "--start", "2026-11-02", "--end", "2026-11-09"],
     "tok-a", WEB),
    (["toggl", "import", "--source", "42", "--project", "Parity Site", "--start", "2026-11-02", "--end", "2026-11-09"],
     "tok-old", WEB),
    (["toggl", "import", *IMPORT], "tok-loop", WEB),
    (["toggl", "import", *IMPORT], "tok-fewer", WEB),
    (["focus", "timeline", "--day", "2026-11-03"], None, WEB),
    (["toggl", "unlink"], None, WEB),
]

CATALOG_ROWS = r"""{"data": [
 {"id": "openai/parity-a", "canonical_slug": "openai/parity-a-1", "pricing": {"prompt": "0.0000010", "completion": "0.000004",
  "input_cache_read": 1e-7, "input_cache_write": 0, "web_search": "abc", "overrides": [
   {"min_prompt_tokens": 300000, "prompt": "0.000002"}, {"min_prompt_tokens": 100000, "completion": "0.000008"},
   {"min_prompt_tokens": 0, "prompt": "1"}, {"min_prompt_tokens": 5, "prompt": "bad"}, "x", {"min_prompt_tokens": true}]}},
 {"id": "anthropic/parity-b", "canonical_slug": 5, "pricing": {"prompt": 0.000003, "completion": "0.000015",
  "overrides": [{"min_prompt_tokens": 200000, "prompt": "0.000006"}]}},
 {"id": "anthropic/parity-c", "pricing": {"prompt": "0.000003", "completion": "0.000015", "input_cache_write_1h": "0.00001"}},
 {"id": "openai/parity-a", "pricing": {"prompt": "0.000001", "completion": "0.000005"}},
 {"id": "Bad/Upper", "pricing": {"prompt": "1", "completion": "1"}},
 {"id": "noslash", "pricing": {"prompt": "1", "completion": "1"}},
 {"id": "x-ai/parity-d", "pricing": {"prompt": "-1", "completion": "1"}},
 {"id": "x-ai/parity-e", "pricing": {"prompt": "101", "completion": "1"}},
 {"id": "x-ai/parity-f", "pricing": {"prompt": null, "completion": "1"}},
 {"id": "x-ai/parity-g", "pricing": "free"},
 {"id": "x-ai/parity-h", "pricing": {"prompt": " 0.5 ", "completion": "1E-6", "input_cache_read": "-0"}},
 "junk", 7]}"""

ACTIVITY = r"""{"data": [
 {"date": "2026-10-21", "model": "openai/gpt-5.5", "usage": 0.10, "requests": 2, "prompt_tokens": 60, "completion_tokens": 40},
 {"date": "2026-10-21", "model": "openai/gpt-5.5", "usage": "0.25", "requests": 1, "prompt_tokens": 6, "completion_tokens": 4},
 {"date": "2026-11-20T00:30:00.000+01:00", "model": null, "model_permaslug": "google/gemini-x", "usage": 1e-3, "requests": "3", "prompt_tokens": 7.0, "completion_tokens": 0},
 {"date": "2026-11-19", "model": "anthropic/claude-x", "usage": 2, "requests": 0, "prompt_tokens": 0, "completion_tokens": 0},
 {"date": "2026-11-01", "model": "openai/gpt-5.5", "usage": 0.0000001, "requests": 1, "prompt_tokens": 1, "completion_tokens": 1},
 {"date": "2026-11-20", "model": "", "usage": "bad"},
 {"date": "2026-10-20", "model": "openai/gpt-5.5", "usage": 9, "requests": 9, "prompt_tokens": 9, "completion_tokens": 9}]}"""

BAD_ACTIVITY = r"""{"data": [{"date": "2026-11-19", "model": "m", "usage": 1.5, "requests": 1.5, "prompt_tokens": 1,
 "completion_tokens": 1}]}"""

TOGGL_ME = {"tok-a": 7, "tok-old": 8, "tok-loop": 8, "tok-badentry": 7, "tok-fewer": 7}
TOGGL_PROJECTS = [{"id": 42, "name": " Website ", "active": True, "workspace_id": 17},
                  {"id": 43, "name": "apple", "active": False, "workspace_id": 0, "wid": 18},
                  {"id": 45, "name": "banana", "active": True, "workspace_id": 17},
                  {"id": 44, "name": "Banana", "workspace_id": None, "wid": 17}]
TOGGL_ENTRIES = [
    {"id": 1001, "project_id": 42, "start": "2026-11-02T17:00:00Z", "stop": "2026-11-02T18:30:00Z", "duration": 5400},
    {"id": 1002, "project_id": None, "pid": 42, "start": "2026-11-03T09:00:00-08:00", "stop": "2026-11-03T10:00:00-08:00"},
    {"id": 1003, "project_id": 43, "start": "2026-11-03T12:00:00Z", "stop": "2026-11-03T13:00:00Z"},
    {"id": 1004, "project_id": 42, "start": "2026-11-04T12:00:00Z", "stop": "2026-11-04T13:00:00Z",
     "server_deleted_at": "2026-11-05T00:00:00Z"},
    {"id": 1005, "project_id": 42, "start": "2026-11-05T10:00:00Z", "stop": None, "duration": -1794000000},
    {"id": 1006, "project_id": 42, "start": "2026-11-06T10:00:00Z", "duration": 1800},
    {"id": 1007, "project_id": 42, "start": "2026-11-06T12:00:00Z", "stop": "2026-11-06T12:00:00Z", "duration": 0},
    {"id": 1008, "project_id": 42, "start": 1794045600, "stop": 1794049200.5},
    {"id": 1001, "project_id": 42, "start": "2026-11-02T19:00:00+00:00", "stop": "2026-11-02T19:45:00.250+00:00"},
    {"id": 1009, "project_id": 42, "start": "2026-11-01T07:59:00Z", "stop": "2026-11-01T09:00:00Z"},
]


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    scenario = ""
    requests = []


class Fixtures(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.answer()

    def do_POST(self):
        self.answer()

    def reply(self, status, body, headers=None):
        data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:
            pass  # the client stopped reading at its size limit

    def answer(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        auth = self.headers.get("Authorization", "")
        self.server.requests.append((self.command, self.path, body.decode(), auth, self.headers.get("Accept"),
                                     (self.headers.get("Content-Type") or "").lower()))
        url = urlsplit(self.path)
        if url.path in ("/api/v1/models", "/api/v1/models-moved"):
            return self.models(url.path)
        if url.path == "/api/v1/activity":
            return self.activity(auth.removeprefix("Bearer "))
        token = base64.b64decode(auth.removeprefix("Basic ")).decode().removesuffix(":api_token") if auth else ""
        return self.toggl(token, url, json.loads(body) if body else None)

    def models(self, path):
        scenario = self.server.scenario
        if scenario == "redirect" and path == "/api/v1/models":
            return self.reply(302, "", {"Location": "/api/v1/models-moved"})
        responses = {"500": (500, "{}"), "nodata": (200, '{"x": 1}'), "list": (200, "[]"),
                     "notlist": (200, '{"data": {}}'), "empty": (200, '{"data": [{"id": "a/b", "pricing": {}}]}'),
                     "big": (200, b" " * (8 * 1024 * 1024 + 1))}
        return self.reply(*responses.get(scenario, (200, CATALOG_ROWS)))

    def activity(self, key):
        responses = {"denied-key": (403, "{}"), "error-key": (500, "{}"), "redirect-key": (302, ""),
                     "big-key": (200, b" " * (8 * 1024 * 1024 + 1)), "junk-key": (200, "not json"),
                     "badrow-key": (200, BAD_ACTIVITY), "good-key": (200, ACTIVITY)}
        status, body = responses.get(key, (401, "{}"))
        return self.reply(status, body, {"Location": "/api/v1/activity"} if status == 302 else None)

    def toggl(self, token, url, payload):
        if token not in TOGGL_ME and token != "tok-badproj":
            return self.reply(401, "{}")
        path, query = url.path, parse_qs(url.query)
        if path == "/api/v9/me":
            return self.reply(200, {"id": TOGGL_ME.get(token, 7), "fullname": "Ada Lovelace", "email": "ada@example.com",
                                    "default_workspace_id": 17})
        if path == "/api/v9/me/workspaces":
            return self.reply(200, [{"id": 17, "name": "Main"}, {"id": 18, "name": ""}, {"id": "x", "name": "Bad"}, 5,
                                    {"id": 19, "name": 12}])
        if path == "/api/v9/me/projects":
            if token == "tok-badproj":
                return self.reply(200, [{"id": 0, "name": "x"}])
            return self.reply(200, TOGGL_PROJECTS if token == "tok-old" else {"items": TOGGL_PROJECTS})
        if path == "/api/v9/me/time_entries":
            if token in ("tok-old", "tok-loop"):
                return self.reply(400, '"start_date must not be earlier than 2026-08-01"')
            if token == "tok-badentry":
                return self.reply(200, [{"id": 1, "project_id": 42, "start": "2026-11-03T10:00:00Z",
                                         "stop": "2026-11-03T09:00:00Z"}])
            start, end = (datetime.fromisoformat(query[name][0]) for name in ("start_date", "end_date"))
            if token == "tok-a" and (end - start).days >= 4:
                return self.reply(200, [{"id": n, "project_id": 999, "start": "2026-11-03T00:00:00Z",
                                         "stop": "2026-11-03T00:01:00Z"} for n in range(1, 1001)])
            entries = TOGGL_ENTRIES[:3] if token == "tok-fewer" else TOGGL_ENTRIES
            return self.reply(200, [e for e in entries if not isinstance(e["start"], str)
                                    or start <= datetime.fromisoformat(e["start"].replace("Z", "+00:00")) < end
                                    or e["id"] == 1009])
        if path == "/reports/api/v3/workspace/17/search/time_entries":
            if token == "tok-loop":
                return self.reply(200, [], {"X-Next-ID": "5"})
            if "first_id" not in payload:
                return self.reply(200, [
                    {"user_id": 8, "project_id": 42, "time_entries": [
                        {"id": 2001, "start": "2026-11-03T10:00:00Z", "stop": "2026-11-03T11:00:00Z", "seconds": 3600}]},
                    {"user_id": 9, "project_id": 42, "time_entries": [{"id": 2009}]},
                    {"user_id": 8, "project_id": 43, "time_entries": "skip"}],
                    {"X-Next-ID": "2002", "X-Next-Row-Number": " 2 ", "X-Next-Timestamp": "1_794_000_000"})
            return self.reply(200, [{"user_id": 8, "project_id": 42, "time_entries": [
                {"id": 2002, "start": "2026-11-04T10:00:00Z", "stop": None, "seconds": 1200}]}])
        return self.reply(404, "{}")

GENERATED = re.compile(r"\b(time|expense):[0-9a-f]{32}\b")
# Rule ids are random uuid4 values.
RULE_ID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b")


def agent_fixtures(home):
    """Logs in each agent's own format: the fixtures of tests/test_harnesses.py, plus Codex and Claude Code."""
    sys.path[:0] = [str(ROOT), str(ROOT / "tests")]
    import test_harnesses

    class Writer(test_harnesses.HarnessTests):
        def sync(self, provider):
            pass

        def usage(self, provider):
            return []

    for name in sorted(dir(test_harnesses.HarnessTests)):
        if name.startswith("test_") and name != "test_every_tool_is_registered":
            case = Writer(name)
            case.home = home
            try:
                getattr(case, name)()  # writes its logs, then fails on the (stubbed) sync's missing rows
            except (AssertionError, ValueError, KeyError, IndexError):
                pass
    write, lines = test_harnesses.write, test_harnesses.lines
    stamp, later = "2026-11-16T09:00:00Z", "2026-11-16T09:01:00Z"

    def event(name, timestamp=stamp, **payload):
        return {"type": "event_msg", "timestamp": timestamp, "payload": dict(payload, type=name)}

    raw = {"input_tokens": 100, "cached_input_tokens": 40, "cache_write_input_tokens": 10, "output_tokens": 15,
           "reasoning_output_tokens": 3}
    context = {"type": "turn_context", "payload": {"turn_id": "t1", "model": "codex-test"}}
    write(home / ".codex/sessions/2026/11/16/rollout-a.jsonl", lines(
        {"type": "session_meta", "payload": {"id": "thread-1", "cwd": "/work/app", "git": {"branch": "feat/CLI-42-export"}}},
        event("task_started", turn_id="t1"), context,
        {"type": "token_usage_record", "timestamp": stamp, "payload": {"turn_id": "t1", "response_id": "r1", "usage": raw}},
        event("token_count", info={"total_token_usage": raw, "last_token_usage": raw}),
        event("task_complete", later, turn_id="t1", duration_ms=60000),
        event("task_started", turn_id="t2"), dict(context, payload=dict(context["payload"], turn_id="t2")),
        event("token_count", info={"total_token_usage": {"input_tokens": 130, "output_tokens": 19},
                                   "last_token_usage": {"input_tokens": 30, "output_tokens": 4}})))
    call = {"type": "api-request", "id": "api-ref", "timestamp": stamp}
    response = {"type": "assistant", "requestId": "req-1", "requestRef": "api-ref", "timestamp": later, "cwd": "/work/app",
                "gitBranch": "feat/CLI-42-export", "message": {"model": "claude-test", "content": "text", "usage": {
                    "input_tokens": 20, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 10, "output_tokens": 3}}}
    write(home / ".claude/projects/p/main.jsonl", lines(
        {"type": "user", "timestamp": stamp, "message": {"role": "user", "content": "hi"}}, call, response, response))
    write(home / ".claude/projects/p/session/subagents/duplicate.jsonl", lines(call, response))
    at = 1795046400000
    record = {"role": "assistant", "providerID": "openrouter", "modelID": "anthropic/claude-opus-4.6",
              "tokens": {"input": 100, "output": 30, "reasoning": 20, "cache": {"read": 70, "write": 40}},
              "time": {"completed": at + 3000}}
    test_harnesses.database(home / "opencode/opencode.db",
                            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER)",
                            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)",
                            ("INSERT INTO session VALUES ('s1', '/work/app', ?)", (at - 1000,)),
                            ("INSERT INTO message VALUES ('m1', 's1', ?, ?)", (at, json.dumps(record))))


def scrub(text):
    return RULE_ID.sub("<uuid>", GENERATED.sub(lambda m: m.group(1) + ":<id>", text))


def normalize(text):
    text = scrub(text)
    try:
        return json.dumps(json.loads(text), sort_keys=True, indent=1)
    except ValueError:
        return text.strip()


def run(engine, cli, ledger, command, stdin=None, overrides=None):
    # Agent locations come only from HOME, never from this machine's settings.
    env = {key: value for key, value in os.environ.items() if not key.endswith(("_HOME", "_DIR", "_ROOT"))}
    env.update({"TRACKER_DB": str(ledger), "HOME": str(ledger.parent), **(overrides or {})})
    if engine == "python":
        # The Python engine in tracker/ is the reference; the app no longer ships it.
        env["PYTHONPATH"] = str(ROOT)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUTF8"] = "1"
        executable = [sys.executable, "-m", "tracker"]
    else:
        executable = [cli]
    result = subprocess.run([*executable, *command], env=env, capture_output=True, text=True, input=stdin or "")
    error = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else ""
    # argparse prints usage lines; only the message matters.
    error = re.sub(r"^.*error: ", "error: ", error)
    error = re.sub(r"^tracker: ", "", error)
    return result.returncode == 0, normalize(result.stdout), error


def tables(ledger):
    conn = sqlite3.connect(ledger)
    dump = {}
    for (name,) in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"):
        rows = [tuple(scrub(v) if isinstance(v, str) else v for v in row)
                for row in conn.execute(f'SELECT * FROM "{name}"')]
        dump[name] = sorted(rows, key=repr)
    schema = sorted(conn.execute("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"))
    conn.close()
    return dump, schema


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("binary", help="Path to TrackerCLI")
    cli.add_argument("--ledger", type=Path, help="Ledger to copy (default: an empty one)")
    args = cli.parse_args()
    binary = str(Path(args.binary).resolve())
    scratch = Path(tempfile.mkdtemp(prefix="tracker-parity-")).resolve()
    differences = 0
    try:
        folder = scratch / "work"
        (folder / "sub").mkdir(parents=True)
        (folder / "real" / "child").mkdir(parents=True)
        (folder / "link").symlink_to(folder / "real" / "child")
        agents = scratch / "agents"
        agents.mkdir()
        agent_fixtures(agents)
        server = FixtureServer(("127.0.0.1", 0), Fixtures)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        http_root = f"http://127.0.0.1:{server.server_address[1]}"
        copies = {}
        for engine in ("python", "swift"):
            target = scratch / engine / "ledger.sqlite3"
            target.parent.mkdir()
            if args.ledger:
                source = sqlite3.connect(f"file:{args.ledger.expanduser().resolve()}?mode=ro", uri=True)
                destination = sqlite3.connect(target)
                source.backup(destination)
                source.close()
                destination.close()
            copies[engine] = target
        for step in SCRIPT + DESKTOP_SCRIPT + NETWORK_SCRIPT:
            if isinstance(step, tuple) and step[0] == "sql":
                for engine in copies:
                    conn = sqlite3.connect(copies[engine])
                    with conn:
                        for statement, params in step[1]:
                            conn.execute(statement, params)
                    conn.close()
                continue
            command, stdin, overrides = (step + (None,))[:3] if isinstance(step, tuple) else (step, None, None)

            def fill(part):
                return part.replace("{folder}", str(folder)).replace("{agents}", str(agents)).replace("{http}", http_root)

            command = [fill(part) for part in command]
            overrides = {key: fill(value) for key, value in (overrides or {}).items()}
            server.scenario = overrides.pop("@models", "")
            results = {}
            for engine in copies:
                server.requests = []
                ok, out, err = run(engine, binary, copies[engine], command, stdin, overrides)
                # Both engines must send the same requests (method, path, body, credentials, Accept, Content-Type).
                results[engine] = (ok, out, err, server.requests)
            # The ledger path is reported by `init` and differs between the copies by design.
            for engine in results:
                ok, out, err, sent = results[engine]
                results[engine] = (ok, out.replace(str(copies[engine]), "<ledger>"), err, sent)
            if results["python"] != results["swift"]:
                differences += 1
                print("DIFF", " ".join(command))
                for engine, (ok, out, err, sent) in results.items():
                    print(f"  {engine}: {'ok' if ok else 'failed'} {err}\n" + "\n".join("    " + l for l in out.splitlines()))
                    for request in sent:
                        print("    sent", request)
        python_tables, python_schema = tables(copies["python"])
        swift_tables, swift_schema = tables(copies["swift"])
        if python_schema != swift_schema:
            differences += 1
            print("DIFF schema")
        for name in sorted(set(python_tables) | set(swift_tables)):
            if python_tables.get(name) != swift_tables.get(name):
                differences += 1
                print(f"DIFF table {name}:\n  python {python_tables.get(name)}\n  swift  {swift_tables.get(name)}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"{len(SCRIPT) + len(DESKTOP_SCRIPT) + len(NETWORK_SCRIPT) - 1} commands, {differences} difference(s)")
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main())
