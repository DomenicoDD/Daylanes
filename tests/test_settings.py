import csv
import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import patch

from tracker import desktop, focus, github, store, toggl


class SettingsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "ledger.sqlite3"

    def test_legacy_plans_and_project_clients_are_available_in_settings(self):
        with sqlite3.connect(self.path) as conn:
            conn.executescript("""
                CREATE TABLE subscriptions (name TEXT PRIMARY KEY, monthly_cents INTEGER NOT NULL);
                INSERT INTO subscriptions VALUES ('Claude Pro', 2000);
                CREATE TABLE projects (name TEXT PRIMARY KEY, client TEXT, kind TEXT NOT NULL);
                INSERT INTO projects VALUES ('Website', 'Acme', 'billable');
            """)
        with store.database(self.path) as conn:
            original = desktop.snapshot(conn)
            self.assertEqual(original["clients"], ["Acme"])
            self.assertEqual(original["subscriptions"]["plans"],
                             [{"name": "Claude Pro", "monthly": "20.00", "provider": None}])
            store.set_subscription(conn, "Claude Pro", "22.00", "Anthropic")
            store.set_subscription(conn, "Claude Pro", "23.00")
        with store.database(self.path) as conn:
            store.save_client(conn, "New Acme", "Acme")
            self.assertEqual(store.get_project(conn, "Website")["client"], "New Acme")
        with store.database(self.path) as conn:
            store.save_client(conn, "Future Client")
            self.assertEqual(store.client_list(conn), ["Future Client", "New Acme"])
            self.assertEqual(store.subscriptions(conn)["plans"],
                             [{"name": "Claude Pro", "monthly": "23.00", "provider": "Anthropic"}])

    def test_failed_github_change_keeps_the_existing_repository_and_routes(self):
        with store.database(self.path) as conn:
            store.create_project(conn, "Site", None, "internal", None)
            github.set_repo(conn, "Site", "owner/previous")
        with store.database(self.path) as conn:
            github.set_pr_route(conn, "Site", 42)
        with patch.object(github, "fetch_prs", side_effect=ValueError("Repository unavailable")):
            with self.assertRaisesRegex(ValueError, "Repository unavailable"), store.database(self.path) as conn:
                github.refresh(conn, "Site", "owner/inaccessible")
        with store.database(self.path) as conn:
            project = store.project_list(conn)[0]
            self.assertEqual((project["github_repo"], project["github_routed_prs"]), ("owner/previous", [42]))

        pull = {"number": 11, "headRefName": "feature", "title": "Add feature", "state": "OPEN",
                "url": "https://github.com/owner/available/pull/11", "isCrossRepository": False}
        with patch.object(github, "fetch_prs", return_value=[pull]):
            with store.database(self.path) as conn:
                self.assertEqual(github.refresh(conn, "Site", "owner/available")["repo"], "owner/available")
                self.assertEqual(store.project_list(conn)[0]["github_routed_prs"], [])
                self.assertEqual(desktop.snapshot(conn)["projects"][0]["github_pull_requests"], [
                    {key: pull[key] for key in ("number", "title", "state", "url")},
                ])

    def test_toggl_import_reconciles_by_account_project_and_date(self):
        with store.database(self.path) as conn:
            store.set_setting(conn, "timezone", "Europe/Rome")
            store.create_project(conn, "Website", "Acme", "billable", None)
            store.create_project(conn, "Other", "Another client", "billable", None)

        started = "2026-11-16T22:30:00Z"
        rows = [
            {"id": 1, "project_id": 42, "start": started, "stop": "2026-11-17T00:30:00Z"},
            {"id": 2, "pid": 42, "start": started, "stop": None, "duration": 600},
            {"id": 3, "pid": 42, "start": started, "stop": None, "duration": -1},
            {"id": 4, "pid": 41, "start": started, "stop": None, "duration": 600},
        ]
        account = 7

        def fetch(key, path, params):
            self.assertEqual(key, "sample-token")
            if path == "/me":
                return {"id": account, "api_token": key}
            self.assertEqual(path, "/me/time_entries")
            self.assertEqual(params, {"start_date": "2026-11-15T23:00:00.000+00:00",
                                      "end_date": "2026-11-16T23:00:00.000+00:00"})
            return rows

        dates = ("2026-11-16", "2026-11-17")
        with patch.object(toggl, "fetch", side_effect=fetch):
            for _ in range(2):
                with store.database(self.path) as conn:
                    self.assertEqual(toggl.import_time(conn, "sample-token", 42, "Website", *dates), {"entries": 2})
            account = 8
            with store.database(self.path) as conn:
                toggl.import_time(conn, "sample-token", 42, "Other", *dates)
            account = 7
            rows.pop(1)
            with store.database(self.path) as conn:
                toggl.import_time(conn, "sample-token", 42, "Website", *dates)

        with store.database(self.path) as conn:
            for dates, expected in [((dates[0], dates[1]), "0.5000"), ((dates[1], "2026-11-18"), "1.5000")]:
                exported = desktop.export_csv(conn, *dates, client="Acme")
                records = list(csv.DictReader(io.StringIO(exported)))
                self.assertEqual([(row["project"], row["hours"], row["time_source"]) for row in records],
                                 [("Website", expected, "toggl")])
        self.assertNotIn(b"sample-token", self.path.read_bytes())

    def test_activity_timeline_mixes_sources_and_splits_imports_at_local_midnight(self):
        with store.database(self.path) as conn:
            store.set_setting(conn, "timezone", "Europe/Rome")
            store.create_project(conn, "Website", None, "internal", None)
            starts = store.parse_at("2026-11-16T22:30:00Z")
            ends = store.parse_at("2026-11-17T00:30:00Z")
            conn.execute("INSERT INTO toggl_time VALUES (?, ?, ?, ?, ?, ?)", (1, 7, 42, "Website", starts, ends))
            focus.record(conn, [{
                "id": "00000000-0000-0000-0000-000000000001", "app_id": "com.test.editor", "app_name": "Editor",
                "started_at": store.parse_at("2026-11-16T23:20:00Z"),
                "ended_at": store.parse_at("2026-11-16T23:40:00Z"), "closed": True,
            }])

            first = focus.timeline(conn, "2026-11-16")
            second = focus.timeline(conn, "2026-11-17")
            self.assertEqual([row["time_source"] for row in first["blocks"]], ["toggl"])
            self.assertEqual([row["time_source"] for row in second["blocks"]], ["automatic", "toggl"])
            automatic, imported = second["blocks"]
            self.assertEqual((automatic["app_name"], automatic["project"]), ("Editor", None))
            self.assertEqual((imported["id"], imported["project"], imported["app_name"]),
                             ("toggl:7:1", "Website", "Toggl Track"))
            self.assertEqual((first["blocks"][0]["started_at"], first["blocks"][0]["ended_at"]),
                             (starts, first["day_end"]))
            self.assertEqual((imported["started_at"], imported["ended_at"]), (second["day_start"], ends))

            week = focus.timeline(conn, "2026-11-17", week=True)["days"]
            self.assertEqual([day["day"] for day in week], [f"2026-11-{number}" for number in range(16, 23)])
            self.assertEqual([day["blocks"] for day in week], [first["blocks"], second["blocks"]] + [[]] * 5)
            clock_change = focus.timeline(conn, "2026-10-25", week=True)["days"][-1]
            self.assertEqual(clock_change["day_end"] - clock_change["day_start"], 25 * 3_600_000)

    def test_toggl_older_dates_use_scoped_paginated_reports(self):
        with store.database(self.path) as conn:
            store.set_setting(conn, "timezone", "Europe/Rome")
            store.create_project(conn, "Historical", None, "internal", None)

        def open_request(request, timeout):
            url = request.full_url
            response = io.BytesIO()
            response.headers = {}
            if "/me/time_entries?" in url:
                message = io.BytesIO(b'"start_date must not be earlier than 2026-08-17"')
                raise HTTPError(url, 400, "Bad Request", {}, message)
            if url.startswith(toggl.BASE_URL + "/me?"):
                rows = {"id": 7}
            elif url.startswith(toggl.BASE_URL + "/me/projects?"):
                rows = [{"id": 42, "workspace_id": 17, "name": "Project A"}]
            else:
                self.assertEqual(url, toggl.REPORTS_URL + "/workspace/17/search/time_entries")
                self.assertEqual(request.get_method(), "POST")
                payload = json.loads(request.data)
                self.assertEqual((payload["user_ids"], payload["project_ids"]), ([7], [42]))
                if "first_row_number" not in payload:
                    response.headers = {"X-Next-ID": "3", "X-Next-Row-Number": "4"}
                    items = [{"id": 1, "start": "2026-08-05T22:00:00Z", "stop": None, "seconds": 60},
                             {"id": 2, "start": "2026-08-06T22:00:00Z", "stop": None, "seconds": 60}]
                else:
                    self.assertEqual((payload["first_id"], payload["first_row_number"]), (3, 4))
                    items = [{"id": 3, "start": "2026-08-06T10:00:00Z", "stop": None, "seconds": 120}]
                rows = [{"user_id": 7, "project_id": 42, "time_entries": items},
                        {"user_id": 8, "project_id": 42, "time_entries": items}]
            response.write(json.dumps(rows).encode())
            response.seek(0)
            return response

        with patch.object(toggl, "build_opener") as new_opener:
            new_opener.return_value.open.side_effect = open_request
            with store.database(self.path) as conn:
                result = toggl.import_time(conn, "sample-token", 42, "Historical", "2026-08-06", "2026-08-07")
                entries = conn.execute("SELECT id, account, ended_at - started_at FROM toggl_time ORDER BY id")
                self.assertEqual(result, {"entries": 2})
                self.assertEqual([tuple(row) for row in entries], [(1, 7, 60_000), (3, 7, 120_000)])


if __name__ == "__main__":
    unittest.main()
