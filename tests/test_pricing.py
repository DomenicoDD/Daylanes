import csv
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tracker import desktop, importers, pricing, reports, store


STAMP = "2026-11-16T09:00:00Z"
WINDOW = {"start": "2026-11-16", "end": "2026-11-17"}
CATALOG = [
    {"id": "anthropic/claude-opus-4.6:batch", "canonical_slug": "anthropic/claude-4.6-opus-20260205",
     "pricing": {"prompt": "0.0000025", "completion": "0.0000125"}},
    {"id": "anthropic/claude-opus-4.6", "canonical_slug": "anthropic/claude-4.6-opus-20260205",
     "pricing": {"prompt": "0.000005", "completion": "0.000025", "input_cache_read": "0.0000005",
                 "input_cache_write": "0.00000625",
                 "overrides": [{"min_prompt_tokens": 200000, "prompt": "0.00001", "completion": "0.0000375"}]}},
    {"id": "google/gemini-test", "pricing": {"prompt": "0.000001", "completion": "0.000004"}},
    {"id": "openai/gpt-test", "canonical_slug": "openai/gpt-test-20261101",
     "pricing": {"prompt": "0.000002", "completion": "0.000008"}},
    {"id": "example/free-model:free", "pricing": {"prompt": "0", "completion": "0"}},
]


class PricingTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = Path(tmp.name) / "ledger.sqlite3"

    def test_reference_catalog_keeps_known_rates_offline_and_resolves_exact_versions(self):
        with store.database(self.db) as conn:
            with patch.object(pricing, "fetch_models", return_value=CATALOG) as fetch:
                self.assertTrue(pricing.refresh(conn)["refreshed"])
                self.assertFalse(pricing.refresh(conn, if_stale=True)["refreshed"])
                fetch.assert_called_once()
            original = pricing.catalog(conn)
            for error in (OSError("offline"), KeyError("data")):
                with patch.object(pricing, "fetch_models", side_effect=error), self.assertRaisesRegex(ValueError, "OpenRouter"):
                    pricing.refresh(conn)
                self.assertEqual(pricing.catalog(conn), original)
            catalog = pricing.Catalog(conn)
            self.assertEqual(catalog.model("claude", "claude-opus-4-6-20260205"), "anthropic/claude-opus-4.6")
            self.assertEqual(catalog.model("codex", "gpt-test-20261101"), "openai/gpt-test")
            self.assertIsNone(catalog.model("claude", "claude-opus-4-6-20260101"))
            # Other agents log bare model names; the family tells the provider.
            self.assertEqual(catalog.model("my-harness", "gpt-test"), "openai/gpt-test")
            self.assertEqual(catalog.model("my-harness", "gemini/gemini-test"), "google/gemini-test")

    def test_mixed_harness_quotes_and_subscription_fees_stay_separate_in_reports(self):
        def source(*rows):
            return io.StringIO("\n".join(json.dumps({"timestamp": STAMP, **row}) for row in rows))

        with store.database(self.db) as conn:
            with patch.object(pricing, "fetch_models", return_value=CATALOG):
                pricing.refresh(conn)
            store.create_project(conn, "Delivery", "Acme", "billable", None)
            store.set_subscription(conn, "ChatGPT Pro", "100.00")
            store.set_subscription(conn, "Claude Pro", "20.00")
            store.add_entry(conn, dict(id="invoice", kind="expense", project="Delivery", at=store.parse_at(STAMP), cents=750))
            rows = (
                dict(id="1", model="openrouter/anthropic/claude-opus-4.6", input=1_000_000,
                     cached=1_000_000, cache_write=1_000_000, output=1_000_000, prompt="Do not store"),
                dict(id="2", model="google/gemini-test", input=1_000_000, output=1_000_000),
                dict(id="3", model="google/gemini-test", input=1000, cached=3000),
                dict(id="4", model="example/free-model:free", input=1000),
            )
            importers.import_harness(conn, "my-harness", source(*rows))
            store.assign(conn, "harness:my-harness:1", "Delivery")
            importers.import_harness(conn, "my-harness", source(*rows))
            store.model_rate(conn, "my-harness", "google/gemini-test", ("2", "0", "0", "3"))

            result = reports.report(conn, **WINDOW)
            totals = result["totals"]
            self.assertEqual(result["currency"], "EUR")
            self.assertEqual(result["subscriptions"]["monthly_total"], "120.00")
            self.assertEqual(totals["provider_expenses"], "7.50")
            self.assertEqual(totals["estimated_token_value"], "5.00")
            # Request 1 reaches the long-context threshold, so its input and output use the override rates.
            self.assertEqual(totals["api_equivalent_usd"], "59.25")
            # Cached tokens without a catalog rate use Google's published 0.1× read multiple.
            self.assertEqual(totals["tokens_without_api_price"], 0)
            self.assertEqual(totals["agents"]["my-harness"]["model_api_equivalent_usd"]["example/free-model:free"], "0.00")
            self.assertEqual(reports.report(conn, project="Delivery", **WINDOW)["totals"]["api_equivalent_usd"], "54.25")
            self.assertIsNone(reports.report(conn, project="Delivery", **WINDOW)["subscriptions"])
            snapshot = desktop.snapshot(conn, **WINDOW)
            self.assertTrue(snapshot["ever_imported"])
            self.assertEqual(snapshot["totals"], totals)
            self.assertNotIn("Do not store", json.dumps(snapshot))

            exported = list(csv.DictReader(io.StringIO(desktop.export_csv(conn, **WINDOW))))
            self.assertEqual(len(exported), 5)
            self.assertEqual(exported[0]["api_equivalent_usd"], "54.25000000")
            self.assertEqual(exported[0]["openrouter_model"], "anthropic/claude-opus-4.6")
            self.assertEqual(exported[0]["actual_expense"], "")
            self.assertEqual(exported[2]["api_equivalent_usd"], "0.00130000")
            self.assertEqual(exported[-1]["actual_expense"], "7.50")
