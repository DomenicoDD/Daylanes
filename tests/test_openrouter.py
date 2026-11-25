import io
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from tracker import desktop, openrouter, reports, store


class OpenRouterActivityTests(unittest.TestCase):
    def test_uses_documented_authenticated_endpoint_and_reports_denial_without_the_key(self):
        key = "mock-management-key"
        opener = Mock()
        opener.open.return_value = io.BytesIO(b'{"data": []}')
        with patch.object(openrouter, "build_opener", return_value=opener):
            self.assertEqual(openrouter.fetch_activity(key), [])
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, "https://openrouter.ai/api/v1/activity")
            self.assertEqual(request.get_header("Authorization"), "Bearer " + key)
            opener.open.side_effect = HTTPError(request.full_url, 403, key, {}, io.BytesIO(b"{}"))
            with self.assertRaisesRegex(ValueError, "activity access") as error:
                openrouter.fetch_activity(key)
            self.assertNotIn(key, str(error.exception))

    def test_account_cache_is_clipped_to_complete_days_and_excluded_from_project_totals(self):
        def row(day, model, spend, **fields):
            return {"date": day, "model": model, "usage": spend, "requests": 2,
                    "prompt_tokens": 60, "completion_tokens": 40, "cached_tokens": 10,
                    "reasoning_tokens": 15, **fields}

        data = [row("2026-11-15", "openai/gpt-test", "0.123"),
                row("2026-11-16T00:30:00.000+01:00", None, "0.187", model_permaslug="openai/gpt-test",
                    requests="2", prompt_tokens="60.0"),
                row("2026-11-14", "google/gemini-test", "0.09"),
                row("2026-11-16", "google/gemini-test", "10.00"),
                row("2026-10-16", "openai/gpt-test", "1.00")]
        window = {"start": "2026-11-15", "end": "2026-11-17"}
        with tempfile.TemporaryDirectory() as tmp, store.database(Path(tmp) / "ledger.db") as conn:
            with patch.object(openrouter, "datetime", wraps=datetime) as clock, \
                 patch.object(openrouter, "fetch_activity", return_value=data) as fetch:
                clock.now.return_value = datetime(2026, 11, 16, 12, tzinfo=timezone.utc)
                self.assertEqual(openrouter.refresh(conn, "key")["groups"], 2)
                account = desktop.snapshot(conn, **window)["openrouter_account"]
                self.assertEqual(account["end_exclusive"], "2026-11-16")
                self.assertEqual(account["totals"], {"spend_usd": "0.31", "requests": 4, "tokens": 200})
                self.assertEqual([model["model"] for model in account["models"]], ["openai/gpt-test"])
                self.assertEqual(reports.report(conn, **window)["totals"]["provider_expenses"], "0.00")
                self.assertIsNone(reports.report(conn, project="Example", **window)["openrouter_account"])

                fetch.return_value = [row("2026-11-15", "openai/gpt-test", "malformed")]
                with self.assertRaisesRegex(ValueError, "invalid activity row .*usage"):
                    openrouter.refresh(conn, "key")
                self.assertEqual(desktop.snapshot(conn, **window)["openrouter_account"], account)

                fetch.return_value = []
                openrouter.refresh(conn, "new-key")
                self.assertEqual(desktop.snapshot(conn, **window)["openrouter_account"]["totals"]["requests"], 0)

            openrouter.clear(conn)
            self.assertIsNone(desktop.snapshot(conn, **window)["openrouter_account"])
