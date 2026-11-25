import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections import defaultdict
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

from tracker import billing, report_rows, store

MINUTE = 60_000
HOUR = 60 * MINUTE
ROOT = Path(__file__).resolve().parent.parent


class FlatCatalog:
    """Prices usage at one US cent per token, and leaves model "free-form" without an API price."""
    fetched_at = None

    def __init__(self, conn=None):
        pass

    def quote(self, entry):
        return None if entry["model"] == "free-form" else Decimal(entry["input"] + entry["output"]) / 100

    def model(self, provider, model):
        return model


def at(text):
    return store.parse_at(text)


class ReportRowsTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = Path(tmp.name) / "ledger.sqlite3"
        catalog = patch.object(report_rows, "Catalog", FlatCatalog)
        catalog.start()
        self.addCleanup(catalog.stop)

    def human(self, conn, entry_id, project, start, minutes, **extra):
        store.add_entry(conn, dict(id=entry_id, kind="human", at=at(start), millis=minutes * MINUTE,
                                   project=project, label="other", **extra))

    def agent(self, conn, session, project, start, minutes, tokens=0, **extra):
        store.add_entry(conn, dict(id=f"codex:{session}:{start}", kind="runtime", at=at(start),
                                   millis=minutes * MINUTE, session=session, provider="codex", project=project,
                                   label="turn elapsed", **extra))
        if tokens:
            store.add_entry(conn, dict(id=f"codex:{session}:{start}:usage", kind="usage", at=at(start) + MINUTE,
                                       session=session, provider="codex", model="m", project=project,
                                       input=tokens, output=0, **extra))

    def seed(self, conn):
        store.create_project(conn, "Site", "Acme", "billable", None)
        store.create_project(conn, "App", "Acme", "billable", None)
        store.create_project(conn, "Shop", "Beta", "billable", None)
        store.create_project(conn, "Ops", "Acme", "internal", None)
        store.create_project(conn, "Notes", None, "personal", None)
        # One hour switching between Site and App: each project bills it. An overlapping Site record counts once.
        self.human(conn, "time:site", "Site", "2026-11-16T09:00:00Z", 60)
        self.human(conn, "time:app", "App", "2026-11-16T09:00:00Z", 60)
        self.human(conn, "time:site:again", "Site", "2026-11-16T09:30:00Z", 50, task="WEB-1")
        # Three thirds of an hour at a rate that does not divide evenly into cents.
        for index, start in enumerate(("2026-11-17T09:00:00Z", "2026-11-17T11:00:00Z", "2026-11-17T13:00:00Z")):
            self.human(conn, f"time:shop:{index}", "Shop", start, 20)
        self.human(conn, "time:ops", "Ops", "2026-11-16T12:00:00Z", 30)
        self.human(conn, "time:notes", "Notes", "2026-11-16T12:00:00Z", 30)
        self.human(conn, "time:loose", None, "2026-11-16T14:00:00Z", 10)
        # Two agent threads on Site in parallel, one crossing midnight.
        self.agent(conn, "a", "Site", "2026-11-16T10:00:00Z", 120, tokens=5000, branch="feature/login")
        self.agent(conn, "b", "Site", "2026-11-16T23:00:00Z", 120, tokens=7001, task="WEB-2")
        self.agent(conn, "c", "Shop", "2026-11-17T10:00:00Z", 7, tokens=333, folder="/work/shop")
        self.agent(conn, "d", "Ops", "2026-11-17T10:00:00Z", 30, tokens=100)
        store.add_entry(conn, dict(id="codex:e:usage", kind="usage", at=at("2026-11-18T08:00:00Z"), session="e",
                                   provider="codex", model="free-form", project="Site", input=40, output=2))
        store.add_entry(conn, dict(id="expense:1", kind="expense", at=at("2026-11-18T09:00:00Z"), project="Site",
                                   label="Fonts", cents=1250, reimbursable=1))
        billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="hybrid", agent_rate="25",
                           markup="1.3")
        billing.save_terms(conn, "client", "Beta", human_rate="100", agent_mode="time", agent_rate="33.33")
        billing.set_exchange_rate(conn, "0.9")

    def build(self, conn, **filters):
        return report_rows.build(conn, "2026-11-16", "2026-11-23", **filters)

    def assert_reconciles(self, result):
        summary = result["billing"]
        totals = defaultdict(Decimal)
        for row in result["rows"]:
            if row["who"] != "expense" and row["amount"] is not None:
                totals[(row["client"], row["project"])] += Decimal(row["amount"])
        for client in summary["clients"]:
            for project in client["projects"]:
                self.assertEqual(totals.pop((client["client"], project["project"]), Decimal(0)),
                                 Decimal(project["subtotal"]), project["project"])
        self.assertFalse(totals)
        rows = sum((Decimal(row["amount"]) for row in result["rows"]
                    if row["who"] != "expense" and row["amount"] is not None), Decimal(0))
        adjustments = sum((Decimal(item["amount"]) for item in result["adjustments"]), Decimal(0))
        self.assertEqual(rows + adjustments, Decimal(summary["total"]))
        ids = [row["id"] for row in result["rows"]]
        self.assertEqual(len(ids), len(set(ids)))
        for row in result["rows"]:
            parts = [Decimal(row[key]) for key in ("time_amount", "usage_amount") if row[key] is not None]
            if row["who"] != "expense":
                self.assertEqual(row["amount"], format(sum(parts), ".2f") if parts else None)

    def rows(self, result, **match):
        return [row for row in result["rows"] if all(row[key] == value for key, value in match.items())]

    def test_rows_reconcile_with_the_invoice(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            result = self.build(conn)
            self.assert_reconciles(result)
            self.assertEqual(result["billing"]["total"], "554.30")
            # Site: the earlier session bills the overlap; the later one only its last 20 minutes.
            [site] = [row for row in self.rows(result, who="you", project="Site") if row["task"] is None]
            [again] = self.rows(result, who="you", project="Site", task="WEB-1")
            self.assertEqual((site["millis"], site["billed_millis"]), (HOUR, HOUR))
            self.assertEqual((again["millis"], again["billed_millis"]), (50 * MINUTE, 20 * MINUTE))
            self.assertEqual(site["rate"], "90.00")
            self.assertEqual(Decimal(site["amount"]) + Decimal(again["amount"]), Decimal("120.00"))
            [app] = self.rows(result, who="you", project="App")
            self.assertEqual((app["billed_millis"], app["amount"]), (HOUR, "90.00"))
            # 20 minutes at 100/h is 33.333…: the three rows share 100.00 to the cent.
            shop = self.rows(result, who="you", project="Shop")
            self.assertEqual(sorted(row["amount"] for row in shop), ["33.33", "33.33", "33.34"])
            # The activity code ("other") is not a description; with no task there is none.
            self.assertEqual(shop[0]["description"], "")
            # Unbilled kinds still list their time without amounts.
            for project in ("Ops", "Notes", None):
                [row] = self.rows(result, who="you", project=project)
                self.assertEqual((row["millis"], row["amount"], row["rate"]), (row["millis"], None, None))
                self.assertGreater(row["millis"], 0)
            [ops_agent] = self.rows(result, who="agent", project="Ops")
            self.assertEqual((ops_agent["agent_mode"], ops_agent["amount"]), (None, None))
            [expense] = self.rows(result, who="expense")
            self.assertEqual((expense["amount"], expense["reimbursable"], expense["description"]),
                             ("12.50", True, "Fonts"))

    def test_agent_threads_split_at_midnight_and_carry_usage(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            result = self.build(conn)
            site = self.rows(result, who="agent", project="Site")
            by_thread = defaultdict(list)
            for row in site:
                by_thread[row["thread"]].append(row)
            [a] = by_thread["a"]
            self.assertEqual((a["millis"], a["description"], a["agent_mode"], a["rate"]),
                             (2 * HOUR, "feature/login", "hybrid", "25.00"))
            self.assertEqual((a["tokens"]["input"], a["api_usd"], a["models"]), (5000, "50.000000", ["m"]))
            first, second = by_thread["b"]
            self.assertEqual((first["date"], second["date"]), ("2026-11-16", "2026-11-17"))
            self.assertEqual((first["millis"], second["millis"]), (HOUR, HOUR))
            self.assertEqual(second["started_at"], at("2026-11-17T00:00:00Z"))
            self.assertEqual((first["task"], first["description"]), ("WEB-2", "WEB-2"))
            self.assertIsNone(second["api_usd"])  # the usage record falls on the first day
            [unpriced] = by_thread["e"]
            self.assertEqual((unpriced["millis"], unpriced["started_at"], unpriced["tokens_without_api_price"]),
                             (0, at("2026-11-18T08:00:00Z"), 42))
            self.assertIsNone(unpriced["api_usd"])
            # Agent time 4 h × 25 = 100.00 spread over the hours; usage 120.01 USD × 1.3 × 0.9 = 140.41.
            self.assertEqual(sum(Decimal(row["time_amount"] or 0) for row in site), Decimal("100.00"))
            self.assertEqual(sum(Decimal(row["usage_amount"] or 0) for row in site), Decimal("140.41"))
            self.assertIsNone(second["usage_amount"])
            [shop] = self.rows(result, who="agent", project="Shop")
            # The project already names the folder: no description rather than repeating it.
            self.assertEqual((shop["description"], shop["agent_mode"], shop["usage_amount"], shop["time_amount"]),
                             ("", "time", None, "3.89"))

    def test_agent_descriptions_skip_generic_branches_and_folders(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Site", "Acme", "billable", None)
            for name, branch in (("main", "main"), ("head", "HEAD"), ("master", "Master"), ("develop", "develop"),
                                 ("dev", "dev"), ("trunk", "TRUNK")):
                self.agent(conn, name, "Site", "2026-11-16T09:00:00Z", 10, tokens=10, branch=branch,
                           folder="/work/site")
            self.agent(conn, "named", "Site", "2026-11-16T10:00:00Z", 10, branch="feature/pay", folder="/work/site")
            self.agent(conn, "tasked", "Site", "2026-11-16T11:00:00Z", 10, branch="feature/pay", task="WEB-9")
            self.agent(conn, "loose", None, "2026-11-16T12:00:00Z", 10, tokens=10, branch="main", folder="/work/loose")
            result = self.build(conn)
            described = {row["thread"]: row["description"] for row in self.rows(result, who="agent")}
            for name in ("main", "head", "master", "develop", "dev", "trunk"):
                self.assertEqual(described[name], "", name)
            self.assertEqual((described["named"], described["tasked"], described["loose"]),
                             ("feature/pay", "WEB-9", "loose"))
            self.assertEqual(report_rows.agent_description(None, " Main ", "/x/y", "Site"), "")
            self.assertEqual(report_rows.agent_description(None, "", "/x/y", None), "y")

    def test_local_timezone_and_human_entries_crossing_midnight(self):
        with store.database(self.db) as conn:
            store.set_setting(conn, "timezone", "Europe/Berlin")
            store.create_project(conn, "Site", "Acme", "billable", None)
            billing.save_terms(conn, "client", "Acme", human_rate="90")
            # 23:30 to 01:30 Berlin time, plus a record from 01:00 to 02:00 that overlaps it.
            self.human(conn, "time:late", "Site", "2026-11-17T22:30:00Z", 120)
            self.human(conn, "time:overlap", "Site", "2026-11-18T00:00:00Z", 60)
            store.add_entry(conn, dict(id="focus-like", kind="human", at=at("2026-11-17T22:00:00Z"),
                                       millis=10 * MINUTE, project="Site", label="other", task="X-1"))
            result = self.build(conn)
            self.assert_reconciles(result)
            rows = self.rows(result, who="you", task=None)
            self.assertEqual([row["date"] for row in rows], ["2026-11-17", "2026-11-18"])
            self.assertEqual([row["millis"] for row in rows], [30 * MINUTE, 120 * MINUTE])
            self.assertEqual(sum(row["billed_millis"] for row in result["rows"]), 160 * MINUTE)
            self.assertEqual(result["billing"]["total"], "240.00")
            self.assertEqual(result["timezone"], "Europe/Berlin")

    def test_sessions_merge_close_records_and_describe_apps(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Site", "Acme", "billable", None)
            store.create_project(conn, "Bare", "Acme", "billable", None)
            for block, app, start, end in (("1", "Xcode", "09:00", "09:40"), ("2", "Safari", "09:45", "09:50"),
                                           ("3", "Xcode", "10:30", "10:40")):
                conn.execute("INSERT INTO focus_blocks VALUES (?, ?, ?, ?, ?, 1, 'Site', 0)",
                             (block, app, app, at(f"2026-11-16T{start}:00Z"), at(f"2026-11-16T{end}:00Z")))
            conn.execute("INSERT INTO focus_matches VALUES ('2', 'domain', 'github.com', 'review')")
            self.human(conn, "time:bare", "Bare", "2026-11-16T09:00:00Z", 30)
            result = self.build(conn)
            self.assert_reconciles(result)
            first, second = self.rows(result, who="you", project="Site")
            self.assertEqual((first["millis"], first["ended_at"], first["tags"]),
                             (45 * MINUTE, at("2026-11-16T09:50:00Z"), ["review"]))
            self.assertEqual((first["description"], second["description"]), ("review", "Xcode"))
            [bare] = self.rows(result, who="you", project="Bare")
            self.assertEqual((bare["rate"], bare["amount"]), (None, None))  # billable without a rate
            self.assertTrue(result["missing_human_rate"])

    def test_records_across_a_month_boundary_bill_like_the_summary(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Site", "Acme", "billable", None)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="time", agent_rate="25")
            # Billing assigns a record to the month it starts in, so these overlaps count in both months.
            self.human(conn, "time:oct", "Site", "2026-10-31T23:00:00Z", 90)
            self.human(conn, "time:nov", "Site", "2026-11-01T00:00:00Z", 60)
            self.agent(conn, "a", "Site", "2026-10-31T23:30:00Z", 60)
            self.agent(conn, "a", "Site", "2026-11-01T00:00:00Z", 15)
            result = report_rows.build(conn, "2026-10-31", "2026-11-02")
            self.assert_reconciles(result)
            self.assertEqual(sum(row["billed_millis"] for row in self.rows(result, who="you")), 150 * MINUTE)
            self.assertEqual(sum(row["billed_millis"] for row in self.rows(result, who="agent")), 75 * MINUTE)
            self.assertEqual(result["billing"]["total"], "256.25")

    def test_usage_without_exchange_rate_and_monthly_cap(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            conn.execute("DELETE FROM settings WHERE key = 'usd_exchange_rate'")
            result = self.build(conn)
            self.assert_reconciles(result)
            self.assertTrue(result["needs_exchange_rate"])
            self.assertTrue(all(row["usage_amount"] is None for row in result["rows"]))
            self.assertIsNotNone(self.rows(result, who="agent", thread="a")[0]["time_amount"])
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="time", agent_rate="25", cap="40")
            result = self.build(conn)
            self.assert_reconciles(result)
            self.assertEqual(result["adjustments"], [{"client": "Acme", "kind": "monthly_cap",
                                                      "monthly_cap": "40.00", "amount": "-60.00"}])

    def test_filters_limit_the_entries_before_billing(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            result = self.build(conn, client="Acme", projects=["Site", "Ops"])
            self.assert_reconciles(result)
            self.assertEqual({row["project"] for row in result["rows"]}, {"Site", "Ops"})
            self.assertEqual((result["client"], result["projects"]), ("Acme", ["Site", "Ops"]))
            self.assertEqual([project["project"] for client in result["billing"]["clients"]
                              for project in client["projects"]], ["Site"])

    def test_share_is_exact_and_deterministic(self):
        rows = [{"id": name} for name in "cab"]
        parts = report_rows.share(100, [(row, Decimal(1)) for row in rows])
        self.assertEqual([(row["id"], cents) for row, cents in parts], [("c", 33), ("a", 34), ("b", 33)])
        self.assertEqual(sum(cents for _, cents in report_rows.share(7, [(rows[0], Decimal(0))])), 7)

    def test_cli_prints_rows(self):
        with store.database(self.db) as conn:
            store.create_project(conn, "Site", "Acme", "billable", None)
            billing.save_terms(conn, "client", "Acme", human_rate="90")
            self.human(conn, "time:site", "Site", "2026-11-16T09:00:00Z", 45)
        output = subprocess.run(
            [sys.executable, "-m", "tracker", "report-rows", "--start", "2026-11-01", "--end", "2026-12-01",
             "--client", "Acme", "--project", "Site", "--project", "Other"],
            cwd=ROOT, env={**os.environ, "TRACKER_DB": str(self.db)}, capture_output=True, text=True, check=True)
        result = json.loads(output.stdout)
        self.assertEqual(result["projects"], ["Site", "Other"])
        self.assertEqual([(row["who"], row["amount"]) for row in result["rows"]], [("you", "67.50")])
        self.assertEqual(result["billing"]["total"], "67.50")


if __name__ == "__main__":
    unittest.main()
