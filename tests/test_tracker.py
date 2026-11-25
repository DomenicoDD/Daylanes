import csv
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tracker import desktop, focus, github, importers, reports, store


STAMP = "2026-11-16T09:00:00Z"
LATER = "2026-11-16T09:01:00Z"
WINDOW = {"start": "2026-11-16", "end": "2026-11-17"}


def write_rows(file, rows):
    file.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def codex_event(name, timestamp=STAMP, **payload):
    return {"type": "event_msg", "timestamp": timestamp, "payload": dict(payload, type=name)}


class TrackerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.db = self.root / "test.sqlite3"
        # Keep agent logs on this machine out of the test ledger.
        environment = {key: value for key, value in os.environ.items() if not key.endswith(("_HOME", "_DIR", "_ROOT"))}
        environment["HOME"] = str(self.root / "home")
        isolated = patch.dict(os.environ, environment, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)
        self.codex = self.root / "codex"
        self.claude = self.root / "claude"
        self.codex.mkdir()
        (self.claude / "session" / "subagents").mkdir(parents=True)
        self.repo = self.root / "client-project"

    def sync(self):
        with store.database(self.db) as conn:
            return importers.sync(conn, codex=self.codex, claude=self.claude)

    def test_captures_legacy_and_current_codex_and_deduplicates_claude(self):
        create = {"type": "session_meta", "payload": {"id": "thread-1", "cwd": str(self.repo),
                                                      "git": {"branch": "feat/CLI-42-export"}}}
        context = {"type": "turn_context", "payload": {"turn_id": "t1", "model": "codex-test"}}
        raw = {"input_tokens": 100, "cached_input_tokens": 40, "cache_write_input_tokens": 10,
               "output_tokens": 15, "reasoning_output_tokens": 3}
        current = {"type": "token_usage_record", "timestamp": STAMP,
                   "payload": {"turn_id": "t1", "response_id": "r1", "usage": raw}}
        legacy = codex_event("token_count", info={"total_token_usage": raw, "last_token_usage": raw})
        complete = codex_event("task_complete", LATER, turn_id="t1", duration_ms=60000)
        first_turn = [create, codex_event("task_started", turn_id="t1"), context, current, current, legacy, complete]
        second_turn = [
            codex_event("task_started", turn_id="t2"),
            dict(context, payload=dict(context["payload"], turn_id="t2")),
            codex_event("token_count", info={"total_token_usage": {"input_tokens": 130, "output_tokens": 19},
                                            "last_token_usage": {"input_tokens": 30, "output_tokens": 4}}),
        ]
        codex_file = self.codex / "history.jsonl"
        write_rows(codex_file, first_turn + second_turn)
        call = {"type": "api-request", "id": "api-ref", "timestamp": STAMP}
        response = {"type": "assistant", "requestId": "req-1", "requestRef": "api-ref",
                    "timestamp": LATER, "cwd": str(self.repo), "gitBranch": "feat/CLI-42-export",
                    "message": {"model": "claude-test", "content": "private test text",
                                "usage": {"input_tokens": 20, "cache_read_input_tokens": 5,
                                          "cache_creation_input_tokens": 10, "output_tokens": 3}}}
        write_rows(self.claude / "main.jsonl", [call, response, response])
        write_rows(self.claude / "session" / "subagents" / "duplicate.jsonl", [call, response])
        self.assertEqual(self.sync()["files_read"], 3)
        self.assertEqual(self.sync()["files_read"], 0)
        with store.database(self.db) as conn:
            self.assertEqual(len(reports.review(conn, **WINDOW)["unassigned"]), 2)
            store.create_project(conn, "Build", "Client", "billable", self.repo.as_posix())
            store.model_rate(conn, "codex", "codex-test", ("10000", "0", "0", "0"))
            report = reports.report(conn, task="cli-42", **WINDOW)
            self.assertEqual(len(report["projects"]), 1)
            stats = report["projects"][0]
            self.assertEqual(stats["client"], "Client")
            self.assertEqual(stats["agents"]["codex"]["tokens"],
                             {"input": 80, "cached": 40, "cache_write": 10, "output": 19})
            self.assertEqual(stats["agents"]["claude"]["tokens"],
                             {"input": 20, "cached": 5, "cache_write": 10, "output": 3})
            self.assertEqual(stats["agents"]["claude"]["runtime_hours"], "0.0167")
            self.assertEqual(stats["estimated_token_value"], "0.80")
            self.assertEqual(stats["tokens_without_price"], 38)
            self.assertEqual(reports.review(conn, **WINDOW)["unassigned"], [])
            store.create_project(conn, "Personal", None, "personal", None)
            store.assign(conn, "codex:turn:t1:codex-test:usage", "Personal")
            self.assertNotIn("private test text", str(list(conn.iterdump())))
        write_rows(codex_file, first_turn + second_turn + [codex_event("task_complete", LATER, turn_id="t2")])
        self.assertEqual(self.sync()["files_read"], 1)
        with store.database(self.db) as conn:
            self.assertEqual(reports.report(conn, project="Personal", **WINDOW)["totals"]["agents"]["codex"]["tokens"]["input"], 50)

    def test_group_assignment_and_export_preserve_accounting_boundaries(self):
        with store.database(self.db) as conn:
            store.set_setting(conn, "timezone", "Europe/Rome")
            at = store.parse_at("2026-11-15T23:30:00Z")
            store.create_project(conn, "Build", "Client", "billable", None)
            store.create_project(conn, "Other", None, "personal", None)
            store.model_rate(conn, "codex", "codex-test", ("100.00", "0", "0", "0"))
            for row in (
                dict(id="manual", kind="human", label="reviewing", millis=1800000, project="Build"),
                dict(id="expense", kind="expense", label="=test", cents=1099, reimbursable=1, project="Build"),
                dict(id="usage", kind="usage", provider="codex", model="codex-test", input=10000,
                     folder=str(self.repo), branch="feat/CLI-42", task="CLI-42"),
                dict(id="run", kind="runtime", provider="codex", millis=3600000, label="turn elapsed",
                     folder=str(self.repo), branch="feat/CLI-42", task="CLI-42"),
                dict(id="other", kind="usage", provider="codex", model="codex-test", input=14000,
                     folder=str(self.repo), branch="feat/CLI-44", task="CLI-44"),
            ):
                store.add_entry(conn, dict(row, at=at))
        with store.database(self.db) as conn:
            self.assertEqual(desktop.assign_group(conn, "Build", "codex", str(self.repo), "feat/CLI-42", None,
                                                  "CLI-42", **WINDOW), {"assigned": 2})
        with store.database(self.db) as conn:
            snapshot = desktop.snapshot(conn, **WINDOW)
            totals = snapshot["project_totals"]["Build"]
            self.assertEqual(totals["human_hours"], "0.5000")
            self.assertEqual(totals["estimated_token_value"], "1.00")
            self.assertEqual(totals["provider_expenses"], "10.99")
            self.assertEqual(sum(row["project"] is None for row in snapshot["activity"]), 1)
            data = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, project="Build", **WINDOW))))
            types = {row["type"]: row for row in data}
            self.assertEqual(len(data), 4)
            self.assertEqual(types["expense"]["activity"], "'=test")
            self.assertEqual(types["expense"]["actual_expense"], "10.99")
            self.assertEqual(types["expense"]["estimated_token_cost"], "")
            self.assertEqual(types["usage"]["estimated_token_cost"], "1.000000")
            self.assertEqual(types["runtime"]["hours"], "1.0000")
            self.assertEqual(types["human"]["hours"], "0.5000")

    def test_github_links_only_unambiguous_branches(self):
        def pr(number, branch, fork=False):
            return {"number": number, "headRefName": branch, "title": "Evidence",
                    "state": "OPEN", "url": f"https://github.com/owner/repo/pull/{number}",
                    "isCrossRepository": fork}

        with store.database(self.db) as conn:
            store.create_project(conn, "Build", "Client", "billable", self.repo.as_posix())
            github.set_repo(conn, "Build", "https://github.com/owner/repo")
            for idx, branch in enumerate(("feat/one", "feat/two", "feat/fork")):
                store.add_entry(conn, dict(id=f"item-{idx}", kind="usage", provider="codex", input=10,
                                           at=store.parse_at(STAMP), folder=str(self.repo.resolve()), branch=branch))
        with patch("tracker.github.fetch_prs", return_value=[
            pr(1, "feat/one"), pr(2, "feat/two"), pr(3, "feat/two"), pr(4, "feat/fork", True),
        ]), store.database(self.db) as conn:
            self.assertEqual(github.refresh(conn, "Build")["pull_requests"], 3)
            by_branch = {item["branch"]: item["pull_request"] for item in desktop.snapshot(conn, **WINDOW)["activity"]}
            self.assertEqual(by_branch["feat/one"]["number"], 1)
            self.assertIsNone(by_branch["feat/two"])
            self.assertIsNone(by_branch["feat/fork"])

    def test_github_routes_agent_worktrees_and_browser_time_to_shared_repo_projects(self):
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "remote", "add", "origin",
                        "git@github.com:Owner/Repo.git"], check=True)
        nested = self.repo / "packages" / "app"
        nested.mkdir(parents=True)
        start = store.parse_at(STAMP)
        key = "1a3e699a-ba3a-4ac3-811e-d4d25966bef5"
        pr = {"number": 42, "headRefName": "feat/pr", "title": "Delivery",
              "state": "OPEN", "url": "https://github.com/Owner/Repo/pull/42", "isCrossRepository": False}
        with store.database(self.db) as conn:
            store.create_project(conn, "Build", "Client A", "billable", None)
            store.create_project(conn, "Delivery", "Client B", "billable", None)
            store.create_project(conn, "Personal", None, "personal", None)
            github.set_repo(conn, "Build", "Owner/Repo")
            for key_id, kind, provider, branch in (
                ("codex-pr", "usage", "codex", "feat/pr"),
                ("claude-pr", "runtime", "claude", "feat/pr"),
                ("codex-general", "usage", "codex", "main"),
            ):
                store.add_entry(conn, dict(id=key_id, kind=kind, provider=provider, branch=branch,
                                           at=start, folder=str(nested.resolve()), input=15, millis=60000))
            self.assertEqual(focus.timeline(conn, "2026-11-16")["agents"][0]["client"], "Client A")
            github.set_repo(conn, "Delivery", "owner/repo")
        with patch("tracker.github.fetch_prs", return_value=[pr]), store.database(self.db) as conn:
            github.refresh(conn, "Build")
        with store.database(self.db) as conn:
            github.set_pr_route(conn, "Delivery", 42)
            self.assertIsNone(focus.config(conn)["github_routes"]["owner/repo"]["project"])
            self.assertEqual(focus.config(conn)["github_routes"]["owner/repo"]["pull_requests"], {42: "Delivery"})
            self.assertEqual(store.project_list(conn)[1]["github_routed_prs"], [42])
            rows = {row["id"]: row for row in reports.scope(conn, **WINDOW, period="week")[1]}
            self.assertEqual((rows["codex-pr"]["project"], rows["codex-pr"]["github_pr"]), ("Delivery", 42))
            self.assertEqual((rows["claude-pr"]["client"], rows["claude-pr"]["github_pr"]), ("Client B", 42))
            self.assertIsNone(rows["codex-general"]["project"])
            store.assign(conn, "codex-pr", "Personal")
            focus.record(conn, [dict(id=key, app_id="com.google.Chrome", app_name="Google Chrome",
                                     started_at=start, ended_at=start + 60000, closed=True,
                                     github={"repo": "owner/repo", "number": 42},
                                     match={"field": "github", "project": "Delivery"})])
            block = focus.timeline(conn, "2026-11-16")["blocks"][0]
            self.assertEqual((block["project"], block["github_repo"], block["github_pr"]), ("Delivery", "owner/repo", 42))
            exported = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, **WINDOW))))
            self.assertEqual({(row["type"], row["project"], row["github_pr"]) for row in exported}, {
                ("usage", "Personal", "42"), ("runtime", "Delivery", "42"),
                ("usage", "", ""), ("human", "Delivery", "42"),
            })
            focus.classify(conn, key, "Personal")
        with store.database(self.db) as conn:
            github.set_pr_route(conn, "Delivery", 42, remove=True)
            block = focus.timeline(conn, "2026-11-16")["blocks"][0]
            self.assertEqual((block["project"], block["github_pr"]), ("Personal", 42))
            rows = {row["id"]: row for row in reports.scope(conn, **WINDOW, period="week")[1]}
            self.assertIsNone(rows["claude-pr"]["project"])
            self.assertEqual(rows["codex-pr"]["project"], "Personal")

    def test_automatic_time_is_reviewed_once_and_split_across_dates(self):
        key = "1a3e699a-ba3a-4ac3-811e-d4d25966bef5"
        start = store.parse_at("2026-11-15T22:45:00Z")
        end = store.parse_at("2026-11-15T23:15:00Z")
        capture = dict(id=key, app_id="com.example.app", app_name="Example", started_at=start)
        previous_day = dict(start="2026-11-15", end="2026-11-16")
        with store.database(self.db) as conn:
            store.set_setting(conn, "timezone", "Europe/Rome")
            store.create_project(conn, "Build", "Client", "billable", None)
            focus.record(conn, [dict(capture, ended_at=end - 5000, closed=False)])
            self.assertFalse(focus.timeline(conn, "2026-11-16")["blocks"][0]["closed"])
            with self.assertRaisesRegex(ValueError, "still being recorded"):
                focus.classify(conn, key, "Build")
            self.assertEqual(reports.report(conn, **WINDOW)["totals"]["human_hours"], "0.0000")
            focus.record(conn, [dict(capture, ended_at=end, closed=True)])
            focus.record(conn, [dict(capture, ended_at=end + 10000, closed=False)])
            focus.classify(conn, key, "Build")
            self.assertEqual(reports.report(conn, **WINDOW)["totals"]["human_hours"], "0.2500")
            self.assertEqual(reports.report(conn, **previous_day)["totals"]["human_hours"], "0.2500")
            self.assertEqual(focus.timeline(conn, "2026-11-16")["blocks"][0]["project"], "Build")
            csv_rows = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, **WINDOW))))
            self.assertEqual([(row["activity"], row["time_source"], row["hours"]) for row in csv_rows],
                             [("Example", "automatic", "0.2500")])
            focus.classify(conn, key, ignored=True)
            self.assertTrue(focus.timeline(conn, "2026-11-16")["blocks"][0]["ignored"])
            self.assertEqual(reports.report(conn, **WINDOW)["totals"]["human_hours"], "0.0000")
            focus.classify(conn, key)
            self.assertFalse(focus.timeline(conn, "2026-11-16")["blocks"][0]["ignored"])

    def test_rule_match_is_reported_only_after_close_and_manual_override_wins(self):
        key = "1a3e699a-ba3a-4ac3-811e-d4d25966bef5"
        start = store.parse_at(STAMP)
        end = start + 30000
        with store.database(self.db) as conn:
            store.create_project(conn, "Build", "Client", "billable", None)
            store.create_project(conn, "Personal", None, "personal", None)
            focus.save_rule(conn, "Build", "window", "Client portal", "Safari", "Review")
            self.assertFalse(focus.config(conn)["enabled"])
            store.set_setting(conn, "focus_enabled", "1")
            self.assertTrue(focus.config(conn)["enabled"])
            rule = focus.config(conn)["rules"][0]
            block = dict(id=key, app_id="com.apple.Safari", app_name="Safari", started_at=start,
                         ended_at=end, closed=False, match=rule, title="private title")
            focus.record(conn, [block])
            self.assertEqual(reports.report(conn, **WINDOW)["totals"]["human_hours"], "0.0000")
            focus.save_rule(conn, "Personal", "app", "Safari", key=rule["id"])
            focus.record(conn, [dict(block, closed=True, ended_at=end+30000)])
            rows = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, **WINDOW))))
            self.assertEqual([(r["project"], r["client"], r["tag"], r["hours"]) for r in rows],
                             [("Build", "Client", "Review", "0.0167")])
            self.assertNotIn("private title", str(list(conn.iterdump())))
            focus.classify(conn, key, "Personal")
            focus.record(conn, [dict(block, closed=True, ended_at=end+60000)])
            restored = focus.timeline(conn, "2026-11-16")["blocks"][0]
            self.assertEqual((restored["project"], restored["tag"], restored["ended_at"]),
                             ("Personal", None, end+30000))

    def test_browser_rules_migrate_and_reject_sensitive_url_parts(self):
        with sqlite3.connect(self.db) as old:
            old.executescript(store.SCHEMA.replace("'app', 'window', 'domain', 'url'", "'app', 'window'")
                              .replace(", chrome_profile TEXT, app_id TEXT", ""))
            store.create_project(old, "Build", "Client", "billable", None)
            old.execute("INSERT INTO focus_rules VALUES ('legacy', 'window', 'Existing title', NULL, NULL, 'Build')")

        with store.database(self.db) as conn:
            focus.save_rule(conn, "Build", "domain", "App.Example.com.")
            focus.save_rule(conn, "Build", "url", "https://APP.Example.com:443/portal/", tag="Research")
            for field, value in (
                ("url", "https://example.com/portal?key=secret"),
                ("url", "https://example.com/portal#fragment"),
                ("url", "https://user:password@example.com/portal"),
                ("domain", "example.com/path"),
                ("domain", "example.com?"),
            ):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    focus.save_rule(conn, "Build", field, value)
            rules = {r["field"]: r for r in focus.config(conn)["rules"]}
            self.assertEqual(rules["window"]["keyword"], "Existing title")
            self.assertEqual(rules["domain"]["keyword"], "app.example.com")
            self.assertEqual(rules["url"]["keyword"], "https://app.example.com/portal")
            self.assertEqual(rules["url"]["tag"], "Research")

    def test_day_activity_keeps_agent_runtime_and_tokens_together_by_project(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Build", "Client", "billable", None)
            at = store.parse_at(STAMP)
            store.add_entry(conn, dict(id="codex-usage", kind="usage", at=at,
                                       provider="codex", project="Build", input=100000, output=40000))
            store.add_entry(conn, dict(id="codex-run", kind="runtime", at=at,
                                       provider="codex", project="Build", millis=600000, label="turn elapsed"))
            store.add_entry(conn, dict(id="claude-usage", kind="usage", at=at,
                                       provider="claude", input=40, folder=str(self.repo)))
            rows = {row["provider"]: row for row in focus.timeline(conn, "2026-11-16")["agents"]}
            self.assertEqual((rows["codex"]["client"], rows["codex"]["project"], rows["codex"]["tokens"],
                              rows["codex"]["runtime_millis"]), ("Client", "Build", 140000, 600000))
            self.assertIsNone(rows["claude"]["runtime_millis"])
            focus.save_rule(conn, "Build", "domain", "mail.google.com", app_scope="Work mail")
            self.assertEqual(focus.config(conn)["rules"][0]["app_scope"], "Work mail")

    def test_day_activity_gives_overlapping_agent_threads_their_own_lanes(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Build", "Client", "billable", None)
            at = store.parse_at(STAMP)
            minute = 60_000
            for session, offset, length in (("a", 0, 30), ("a", 32, 10), ("b", 10, 20), ("c", 70, 5), ("d", 50, 5)):
                store.add_entry(conn, dict(id=f"codex:{session}:{offset}:runtime", kind="runtime",
                                           at=at + offset * minute, millis=length * minute, session=session,
                                           provider="codex", project="Build", label="turn elapsed"))
            store.add_entry(conn, dict(id="codex:a:usage", kind="usage", at=at + 33 * minute, session="a",
                                       provider="codex", project="Build", input=500, output=100))
            store.add_entry(conn, dict(id="claude:x:usage", kind="usage", at=at + 5 * minute, session="x",
                                       provider="claude", input=40, folder=str(self.repo)))
            threads = {row["session"]: row for row in focus.timeline(conn, "2026-11-16")["agent_threads"]}
            self.assertEqual(len(threads["a"]["runs"]), 1)  # the 2-minute gap is merged into one block
            self.assertEqual(threads["a"]["runtime_millis"], 40 * minute)  # but not counted as runtime
            self.assertEqual(threads["a"]["runs"][0]["ended_at"] - at, 42 * minute)
            self.assertEqual(threads["a"]["tokens"], 600)
            # d starts 8 minutes after a ends, too close to share its lane; c is far enough away.
            self.assertEqual([threads[key]["lane"] for key in "abcd"], [0, 1, 0, 1])
            self.assertEqual(threads["a"]["client"], "Client")
            self.assertEqual(threads["x"]["lane"], 0)
            self.assertEqual(threads["x"]["runs"][0]["ended_at"] - threads["x"]["runs"][0]["started_at"], minute)

    def test_internal_and_personal_projects_belong_to_your_own_client(self):
        with sqlite3.connect(self.db) as old:
            old.executescript(store.SCHEMA)
            old.execute("INSERT INTO projects VALUES ('Legacy', NULL, 'internal')")
        with store.database(self.db) as conn:
            self.assertEqual(store.get_project(conn, "Legacy")["client"], "Me")
            store.create_project(conn, "Side", None, "personal", None)
            self.assertEqual(store.get_project(conn, "Side")["client"], "Me")
            with self.assertRaises(ValueError):
                store.create_project(conn, "Paid", None, "billable", None)
            conn.commit()
            store.save_client(conn, "Domenico Studio", previous="Me")
            self.assertEqual(store.self_client(conn), "Domenico Studio")
            store.create_project(conn, "Later", None, "internal", None)
            self.assertEqual(store.get_project(conn, "Later")["client"], "Domenico Studio")

    def test_chrome_profile_scope_upgrades_existing_browser_rules(self):
        with sqlite3.connect(self.db) as old:
            old.executescript(store.SCHEMA.replace(", chrome_profile TEXT, app_id TEXT", ""))
            store.create_project(old, "Build", "Client", "billable", None)
            old.execute("INSERT INTO focus_rules VALUES ('legacy', 'domain', 'mail.google.com', 'Work mail', NULL, 'Build')")
        with store.database(self.db) as conn:
            original = focus.config(conn)["rules"][0]
            self.assertEqual(original["app_scope"], "Work mail")
            self.assertIsNone(original["chrome_profile"])
            focus.save_rule(conn, "Build", "domain", "mail.google.com", key="legacy", chrome_profile="Work")
            self.assertEqual(focus.config(conn)["rules"][0]["chrome_profile"], "Work")
            with self.assertRaisesRegex(ValueError, "Choose a domain or URL"):
                focus.save_rule(conn, "Build", "app", "Chrome", chrome_profile="Work")

    def test_installed_app_rule_preserves_existing_name_and_browser_rules(self):
        with sqlite3.connect(self.db) as old:
            old.executescript(store.SCHEMA.replace(", app_id TEXT\n);", "\n);"))
            store.create_project(old, "Build", "Client", "billable", None)
            old.execute("INSERT INTO focus_rules VALUES ('name', 'app', 'Mail', NULL, NULL, 'Build', NULL)")
            old.execute("INSERT INTO focus_rules VALUES ('tab', 'domain', 'mail.google.com', NULL, NULL, 'Build', 'Work')")
        with store.database(self.db) as conn:
            rules = {r["id"]: r for r in focus.config(conn)["rules"]}
            self.assertIsNone(rules["name"]["app_id"])
            self.assertEqual(rules["tab"]["chrome_profile"], "Work")
            focus.save_rule(conn, "Build", "app", "Mail", key="name", app_id="com.apple.mail")
            self.assertEqual(focus.config(conn)["rules"][0]["app_id"], "com.apple.mail")
            focus.save_rule(conn, "Build", "app", "Mail", key="name")
            self.assertIsNone(focus.config(conn)["rules"][0]["app_id"])

    def test_cli_then_mcp_reports_from_same_database(self):
        base = [sys.executable, "-m", "tracker", "--db", str(self.db)]
        subprocess.run(base + ["project", "add", "Build", "--client", "Client", "--kind", "billable"], check=True)

        subprocess.run(base + ["time", "Build", "--minutes", "45", "--at", STAMP], check=True, capture_output=True)
        calls = [
            {"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
            {"method": "notifications/initialized"},
            {"id": 2, "method": "tools/list"},
            {"id": 3, "method": "tools/call", "params": {"name": "usage_report", "arguments": {"client": "Client", **WINDOW}}},
            {"id": 4, "method": "tools/call", "params": {"name": "usage_report", "arguments": {"client": 123}}},
        ]
        process = subprocess.run(
            base + ["mcp"], input="".join(json.dumps(dict(call, jsonrpc="2.0")) + "\n" for call in calls),
            text=True, capture_output=True, check=True,
        )
        responses = {row["id"]: row["result"] for row in map(json.loads, process.stdout.splitlines())}
        self.assertEqual(responses[1]["protocolVersion"], "2025-11-25")
        self.assertEqual(len(responses[2]["tools"]), 3)
        self.assertEqual(json.loads(responses[3]["content"][0]["text"])["totals"]["human_hours"], "0.7500")
        self.assertTrue(responses[4]["isError"])


if __name__ == "__main__":
    unittest.main()
