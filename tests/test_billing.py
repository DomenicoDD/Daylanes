import csv
import io
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

from tracker import billing, desktop, focus, reports, store

DAY = "2026-11-16T09:00:00Z"
MINUTE = 60_000
HOUR = 60 * MINUTE


class FlatCatalog:
    """Prices every usage entry at one US cent per token, so API values are easy to read."""
    fetched_at = None

    def quote(self, entry):
        return Decimal(entry["input"] + entry["output"]) / 100

    def model(self, provider, model):
        return model


class BillingTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = Path(tmp.name) / "ledger.sqlite3"

    def seed(self, conn):
        at = store.parse_at(DAY)
        store.create_project(conn, "Site", "Acme", "billable", None)
        store.create_project(conn, "App", "Acme", "billable", None)
        store.create_project(conn, "Notes", None, "personal", None)
        # One hour where you switch between Site and App: each project bills the full hour.
        for project in ("Site", "App"):
            store.add_entry(conn, dict(id=f"time:{project}", kind="human", at=at, millis=HOUR, project=project))
        # A duplicate record inside Site's hour counts once.
        store.add_entry(conn, dict(id="time:Site:again", kind="human", at=at + 30 * MINUTE, millis=30 * MINUTE,
                                   project="Site"))
        store.add_entry(conn, dict(id="time:Notes", kind="human", at=at, millis=HOUR, project="Notes"))
        # Two agent threads on Site running in parallel for two hours each.
        for session in ("a", "b"):
            store.add_entry(conn, dict(id=f"codex:{session}", kind="runtime", at=at, millis=2 * HOUR,
                                       session=session, provider="codex", project="Site", label="turn elapsed"))
            store.add_entry(conn, dict(id=f"codex:{session}:usage", kind="usage", at=at + MINUTE, session=session,
                                       provider="codex", model="m", project="Site", input=5000, output=1000))
        return at

    def entries(self, conn):
        return reports.scope(conn, "2026-11-16", "2026-11-17", "week")[1]

    def test_rates_overlap_and_agent_modes(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="hybrid", agent_rate="25",
                               markup="1.3")
            billing.save_terms(conn, "project", "App", human_rate="120")
            billing.set_exchange_rate(conn, "0.9")
            result = billing.summary(conn, self.entries(conn), FlatCatalog())
            [acme] = result["clients"]
            lines = {(row["project"], line["item"]): line for row in acme["projects"] for line in row["lines"]}
            self.assertEqual(lines[("Site", "you")]["hours"], "1.0000")
            self.assertEqual(lines[("Site", "you")]["amount"], "90.00")
            self.assertEqual(lines[("App", "you")]["amount"], "120.00")  # project override
            self.assertEqual(lines[("Site", "agent_time")]["hours"], "4.0000")  # parallel threads add up
            self.assertEqual(lines[("Site", "agent_time")]["amount"], "100.00")
            # 12,000 tokens at a cent = $120 × 1.3 markup × 0.9 = 140.40
            self.assertEqual(lines[("Site", "agent_usage")]["api_usd"], "120.00")
            self.assertEqual(lines[("Site", "agent_usage")]["amount"], "140.40")
            self.assertEqual(acme["total"], "450.40")
            self.assertNotIn("Me", [client["client"] for client in result["clients"]])  # personal work is not billed

    def test_time_only_and_usage_only(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="time", agent_rate="25")
            billing.save_terms(conn, "project", "App", agent_mode="usage")
            result = billing.summary(conn, self.entries(conn), FlatCatalog())
            items = {(row["project"], line["item"]) for row in result["clients"][0]["projects"] for line in row["lines"]}
            self.assertIn(("Site", "agent_time"), items)
            self.assertNotIn(("Site", "agent_usage"), items)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="usage", markup="2")
            result = billing.summary(conn, self.entries(conn), FlatCatalog())
            site = next(row for row in result["clients"][0]["projects"] if row["project"] == "Site")
            usage = next(line for line in site["lines"] if line["item"] == "agent_usage")
            self.assertIsNone(usage["amount"])  # EUR ledger without an exchange rate
            self.assertTrue(result["needs_exchange_rate"])

    def test_monthly_cap_limits_agent_lines(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="time", agent_rate="25", cap="40")
            result = billing.summary(conn, self.entries(conn), FlatCatalog())
            [acme] = result["clients"]
            self.assertEqual(acme["cap_reduction"], "60.00")  # 100 of agent time, capped at 40
            self.assertEqual(acme["total"], "220.00")  # 90 + 90 (App inherits) + 100 − 60
            with self.assertRaises(ValueError):
                billing.save_terms(conn, "project", "Site", cap="10")

    def test_day_view_billing_columns_and_csv(self):
        with store.database(self.db) as conn:
            at = self.seed(conn)
            billing.save_terms(conn, "client", "Acme", human_rate="90", agent_mode="time", agent_rate="25")
            day = focus.timeline(conn, "2026-11-16")["billing"]
            you = {span["project"]: span for span in day["you"]}
            self.assertEqual(set(you), {"Site", "App"})
            self.assertEqual(sorted(span["lane"] for span in day["you"]), [0, 1])  # overlapping projects
            self.assertEqual(you["Site"]["billed_millis"], HOUR)
            [agents] = day["ai"]
            self.assertEqual((agents["threads"], agents["billed_millis"], agents["amount"]), (2, 4 * HOUR, "100.00"))
            self.assertEqual(agents["started_at"], at)
            rows = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, start="2026-11-16", end="2026-11-17"))))
            invoice = [(row["project"], row["activity"], row["bill_amount"]) for row in rows if row["type"] == "invoice"]
            self.assertEqual(invoice, [("App", "Your time", "90.00"), ("Site", "Your time", "90.00"),
                                       ("Site", "Agent time", "100.00")])

    def test_client_rename_keeps_terms(self):
        with store.database(self.db) as conn:
            self.seed(conn)
            billing.save_terms(conn, "client", "Acme", human_rate="90")
            conn.commit()
            store.save_client(conn, "Acme Inc", previous="Acme")
            self.assertEqual(billing.terms_listing(conn)["clients"][0], {
                "name": "Acme Inc", "human_rate": "90.00", "agent_mode": None, "agent_rate": None,
                "usage_markup": None, "monthly_cap": None})
            billing.save_terms(conn, "client", "Acme Inc")
            self.assertEqual(billing.terms_listing(conn)["clients"], [])


if __name__ == "__main__":
    unittest.main()


class TogglAccountTests(unittest.TestCase):
    def test_link_remembers_account_and_workspace_without_the_token(self):
        from unittest.mock import patch
        from tracker import toggl
        replies = {"/me": {"fullname": "Dom", "email": "d@example.com", "default_workspace_id": 2},
                   "/me/workspaces": [{"id": 1, "name": "Studio"}, {"id": 2, "name": "Personal"}]}
        with tempfile.TemporaryDirectory() as folder, store.database(Path(folder) / "l.sqlite3") as conn, \
                patch.object(toggl, "fetch", lambda key, path, params: replies[path]):
            details = toggl.link(conn, "secret-token")
            self.assertEqual(details["workspace_id"], 2)
            self.assertNotIn("secret-token", store.setting(conn, "toggl_account", ""))
            self.assertEqual(toggl.choose_workspace(conn, 1)["workspace_id"], 1)
            with self.assertRaises(ValueError):
                toggl.choose_workspace(conn, 9)
            toggl.unlink(conn)
            self.assertIsNone(toggl.linked(conn))


class AppearanceTests(unittest.TestCase):
    def test_client_icon_and_project_colour(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            image = root / "logo.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 20)
            with store.database(root / "l.sqlite3") as conn:
                store.create_project(conn, "Site", "Acme", "billable", None)
                store.set_appearance(conn, "client", "Acme", root / "icons", icon=str(image))
                store.set_appearance(conn, "project", "Site", root / "icons", color="#3478f6")
                rows = {row["scope"]: row for row in store.appearance_list(conn)}
                self.assertEqual(rows["project"]["color"], "#3478F6")
                self.assertTrue(Path(rows["client"]["icon"]).is_file())
                self.assertEqual(Path(rows["client"]["icon"]).parent, root / "icons")
                with self.assertRaises(ValueError):
                    store.set_appearance(conn, "project", "Site", root / "icons", color="blue")
                (root / "notes.txt").write_text("hi")
                with self.assertRaises(ValueError):
                    store.set_appearance(conn, "client", "Acme", root / "icons", icon=str(root / "notes.txt"))
                conn.commit()
                store.save_client(conn, "Acme Inc", previous="Acme")
                self.assertEqual([row["name"] for row in store.appearance_list(conn) if row["scope"] == "client"],
                                 ["Acme Inc"])
                store.set_appearance(conn, "project", "Site", root / "icons", color="")
                self.assertEqual([row["scope"] for row in store.appearance_list(conn)], ["client"])


class AutomaticRuleTests(unittest.TestCase):
    def test_names_become_window_rules(self):
        from tracker import focus
        with tempfile.TemporaryDirectory() as folder, store.database(Path(folder) / "l.sqlite3") as conn:
            store.create_project(conn, "Lumen Dashboard", "Lumen Labs", "billable", None)
            store.create_project(conn, "Lumen Mobile", "Lumen Labs", "billable", None)
            store.create_project(conn, "Nord Website", "Studio Nord", "billable", None)
            store.create_project(conn, "Tracker", None, "internal", None)
            store.create_project(conn, "UI", "Acme", "billable", None)
            store.create_project(conn, "x" * 151, None, "internal", None)  # longer than a rule keyword may be
            rules = {rule["keyword"]: rule["project"] for rule in focus.config(conn)["auto_rules"]}
            # Project names always count; a client name only when the client has one project.
            self.assertEqual(rules, {"Lumen Dashboard": "Lumen Dashboard", "Lumen Mobile": "Lumen Mobile",
                                     "Nord Website": "Nord Website", "Studio Nord": "Nord Website",
                                     "Tracker": "Tracker", "Acme": "UI"})  # "UI" is too short
            focus.set_auto_rules(conn, "Nord Website", False)
            config = focus.config(conn)
            self.assertNotIn("Nord Website", {rule["project"] for rule in config["auto_rules"]})
            self.assertEqual(config["auto_rules_off"], ["Nord Website"])
            focus.set_auto_rules(conn, "Nord Website", True)
            self.assertIn("Studio Nord", {rule["keyword"] for rule in focus.config(conn)["auto_rules"]})
            with self.assertRaises(ValueError):
                focus.set_auto_rules(conn, "Nope", False)
            # A block matched by an automatic rule records like any window rule.
            [auto] = [rule for rule in focus.config(conn)["auto_rules"] if rule["keyword"] == "Tracker"]
            focus.record(conn, [dict(id="00000000-0000-4000-8000-000000000001", app_id="com.apple.Terminal",
                                     app_name="Terminal", started_at=1_700_000_000_000,
                                     ended_at=1_700_000_060_000, closed=True, match=auto)])
            self.assertEqual(conn.execute("SELECT project FROM focus_blocks").fetchone()[0], "Tracker")
