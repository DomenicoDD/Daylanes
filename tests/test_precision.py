import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

from tracker import blocks, importers, pricing, store

VENDOR = Path(__file__).resolve().parents[1] / "vendor" / "zstd"


def at(clock, day="2026-11-16"):
    return f"{day}T{clock}Z"


def lines(rows):
    return "".join(json.dumps(row) + "\n" for row in rows).encode()


def zstd_frame(data):
    """A valid zstd frame made of raw (stored) blocks, so tests need no compressor."""
    out = bytearray(struct.pack("<I", 0xFD2FB528)) + bytes([0x00, 0x50])  # no content size, 1 MB window
    chunks = [data[i:i + 65536] for i in range(0, len(data), 65536)] or [b""]
    for index, chunk in enumerate(chunks):
        last = index == len(chunks) - 1
        out += (len(chunk) << 3 | int(last)).to_bytes(3, "little") + chunk
    return bytes(out)


CATALOG = [
    {"id": "anthropic/claude-opus-4.6", "canonical_slug": "anthropic/claude-4.6-opus-20260205",
     "pricing": {"prompt": "0.000005", "completion": "0.000025", "input_cache_read": "0.0000005",
                 "input_cache_write": "0.00000625", "web_search": "0.01"}},
    {"id": "openai/gpt-5.4", "pricing": {"prompt": "0.000002", "completion": "0.000016",
                                         "input_cache_read": "0.0000002"}},
    {"id": "openai/gpt-5.6-luna", "pricing": {"prompt": "0.000001", "completion": "0.000008"}},
]


def claude_reply(request, message, usage, **extra):
    return {"type": "assistant", "timestamp": at("09:01:00"), "sessionId": "s1", "requestId": request,
            "cwd": "/work/app", "message": {"id": message, "model": "claude-opus-4-6", "usage": usage}, **extra}


class PrecisionTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.db = self.root / "ledger.sqlite3"
        # Keep agent logs on this machine out of the test ledger.
        environment = {key: value for key, value in os.environ.items() if not key.endswith(("_HOME", "_DIR", "_ROOT"))}
        environment["HOME"] = str(self.root / "home")
        isolated = patch.dict(os.environ, environment, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)
        self.claude = self.root / "claude"
        self.codex = self.root / "codex"
        self.claude.mkdir()
        self.codex.mkdir()

    def sync(self, **options):
        with store.database(self.db) as conn:
            return importers.sync(conn, provider=options.pop("provider", "all"), codex=self.codex,
                                  claude=self.claude, opencode=":memory:", **options)

    def usage(self):
        with store.database(self.db) as conn:
            return {row["id"]: dict(row) for row in conn.execute("SELECT * FROM entries WHERE kind = 'usage'")}

    def catalog(self):
        with store.database(self.db) as conn:
            with patch.object(pricing, "fetch_models", return_value=CATALOG):
                pricing.refresh(conn)
            return pricing.Catalog(conn)

    def test_claude_detail_prices_one_hour_writes_fast_mode_and_web_searches(self):
        usage = {"input_tokens": 1000, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 3000,
                 "cache_creation": {"ephemeral_1h_input_tokens": 2000, "ephemeral_5m_input_tokens": 1000},
                 "output_tokens": 100, "server_tool_use": {"web_search_requests": 2}}
        (self.claude / "app").mkdir()
        (self.claude / "app" / "s1.jsonl").write_bytes(lines([
            claude_reply("r1", "msg_1", usage),
            claude_reply("r2", "msg_2", dict(usage, speed="fast"), timestamp=at("09:02:00")),
            claude_reply("r3", "msg_3", usage, costUSD=0.5),
        ]))
        self.sync()
        catalog = self.catalog()
        entries = self.usage()
        standard = entries["claude:r1:usage"]
        self.assertEqual((standard["cache_write"], standard["cache_write_1h"], standard["web_searches"]), (3000, 2000, 2))
        # 1000 × $5/M + 1000 × $6.25/M (5m) + 2000 × $10/M (1h, 2× input) + 100 × $25/M, plus 2 searches × $0.01.
        tokens = Decimal("0.005") + Decimal("0.00625") + Decimal("0.02") + Decimal("0.0025")
        self.assertEqual(catalog.quote(standard), tokens + Decimal("0.02"))
        # Fast mode on Opus 4.6 bills the tokens at six times the standard rate; searches are not multiplied.
        self.assertEqual(entries["claude:r2:usage"]["tier"], "fast")
        self.assertEqual(catalog.quote(entries["claude:r2:usage"]), tokens * 6 + Decimal("0.02"))
        # A cost the agent recorded is used as is.
        self.assertEqual(catalog.quote(entries["claude:r3:usage"]), Decimal("0.5"))
        self.assertEqual(catalog.estimate(entries["claude:r3:usage"]), tokens + Decimal("0.02"))

    def test_claude_subagent_replays_count_once_and_advisor_calls_count_on_their_own(self):
        usage = {"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}
        advised = dict(usage, iterations=[
            {"type": "message", "input_tokens": 10, "output_tokens": 5},
            {"type": "advisor_message", "model": "claude-fable-5-2", "input_tokens": 400, "output_tokens": 50}])
        (self.claude / "app").mkdir()
        (self.claude / "app" / "s1.jsonl").write_bytes(lines([
            claude_reply("r1", "msg_1", advised),
            # The same response replayed into a subagent's transcript under another request id.
            claude_reply("r9", "msg_1", usage, isSidechain=True),
            # A subagent's own work is kept.
            claude_reply("r2", "msg_2", usage, isSidechain=True),
            # Progress records carry a subagent's message inside data.message.
            {"type": "progress", "timestamp": at("09:03:00"), "sessionId": "s1", "cwd": "/work/app",
             "data": {"message": {"requestId": "r3", "message": {
                 "id": "msg_3", "role": "assistant", "model": "claude-opus-4-6", "usage": usage}}}},
        ]))
        self.sync()
        entries = self.usage()
        self.assertEqual(set(entries), {"claude:r1:usage", "claude:r2:usage", "claude:r3:usage",
                                        "claude:r1:advisor:1:usage"})
        advisor = entries["claude:r1:advisor:1:usage"]
        self.assertEqual((advisor["model"], advisor["input"], advisor["output"]), ("claude-fable-5-2", 400, 50))
        self.assertEqual(entries["claude:r1:usage"]["input"], 10)

    def test_codex_review_model_and_speed_tiers(self):
        catalog = self.catalog()
        entry = dict(provider="codex", model="codex-auto-review", input=1000, cached=0, cache_write=0, output=0)
        before = int(pricing.AUTO_REVIEW_SWITCH) - 1
        self.assertEqual(catalog.estimate(dict(entry, at=before)), Decimal("0.002"))
        self.assertEqual(catalog.estimate(dict(entry, at=pricing.AUTO_REVIEW_SWITCH)), Decimal("0.001"))
        gpt = dict(entry, model="gpt-5.4", at=before)
        self.assertEqual(catalog.estimate(dict(gpt, tier="fast")), Decimal("0.004"))
        self.assertEqual(catalog.estimate(dict(gpt, tier="flex")), Decimal("0.001"))
        self.assertEqual(pricing.tier_multiplier("ultrafast", "openai/gpt-6.1-sol"), 6)
        self.assertEqual(pricing.tier_multiplier("fast", "anthropic/claude-opus-4.8"), 2)
        self.assertEqual(pricing.tier_multiplier("fast", "anthropic/claude-sonnet-4.6"), 1)

    def test_codex_priority_tier_and_forked_logs(self):
        def record(turn, response, tokens, clock="09:01:00"):
            return {"type": "token_usage_record", "timestamp": at(clock),
                    "payload": {"turn_id": turn, "response_id": response, "model": "gpt-5.4",
                                "usage": {"input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 10}}}

        parent = [{"type": "session_meta", "timestamp": at("09:00:00"), "payload": {"id": "parent", "cwd": "/work/app"}},
                  {"type": "event_msg", "timestamp": at("09:00:01"), "payload": {
                      "type": "thread_settings_applied", "thread_settings": {"service_tier": "priority"}}},
                  record("t1", "r1", 100)]
        # The fork copies the parent's turn before its own.
        fork = [{"type": "session_meta", "timestamp": at("09:05:00"),
                 "payload": {"id": "fork", "cwd": "/work/app", "forked_from_id": "parent", "timestamp": at("09:05:00")}},
                *parent[1:], record("t2", "r2", 200, "09:06:00")]
        (self.codex / "parent.jsonl").write_bytes(lines(parent))
        (self.codex / "fork.jsonl").write_bytes(lines(fork))
        self.sync(provider="codex")
        entries = self.usage()
        self.assertEqual(set(entries), {"codex:turn:t1:gpt-5.4:fast:usage", "codex:turn:t2:gpt-5.4:fast:usage"})
        self.assertEqual(sum(row["input"] for row in entries.values()), 300)

    def test_legacy_forked_codex_logs_skip_the_copied_history(self):
        def count(clock, total):
            return {"type": "event_msg", "timestamp": at(clock), "payload": {"type": "token_count", "info": {
                "total_token_usage": {"input_tokens": total, "output_tokens": 0},
                "last_token_usage": {"input_tokens": 100, "output_tokens": 0}}}}

        meta = {"type": "session_meta", "timestamp": at("09:05:00"),
                "payload": {"id": "fork", "forked_from_id": "parent", "timestamp": at("09:05:00")}}
        (self.codex / "fork.jsonl").write_bytes(lines([
            meta, {"type": "turn_context", "timestamp": at("09:05:00"), "payload": {"model": "gpt-5.4"}},
            count("09:05:00", 100), count("09:05:01", 200), count("09:10:00", 300)]))
        self.sync(provider="codex")
        self.assertEqual(sum(row["input"] for row in self.usage().values()), 100)

    def test_codex_rate_limits_are_kept(self):
        limits = {"primary": {"used_percent": 42.0, "window_minutes": 300, "resets_at": 1790000000},
                  "secondary": {"used_percent": 80.0, "window_minutes": 10080, "resets_at": 1700000000},
                  "plan_type": "pro"}
        (self.codex / "a.jsonl").write_bytes(lines([
            {"type": "event_msg", "timestamp": at("09:00:00"),
             "payload": {"type": "token_count", "info": None, "rate_limits": limits}}]))
        self.sync(provider="codex")
        with store.database(self.db) as conn:
            saved = json.loads(store.setting(conn, "codex_rate_limits", "null"))
            plan = blocks.usage_blocks(conn, now=1789990000000)["plan_limits"]
        self.assertEqual(saved["primary"]["used_percent"], 42.0)
        self.assertEqual(plan[0]["plan_type"], "pro")
        primary, weekly = plan[0]["windows"]
        self.assertEqual((primary["used_percent"], primary["resets_in_minutes"]), (42.0, 166))
        # The weekly window reset after the log was written, so its old percentage no longer applies.
        self.assertEqual((weekly["used_percent"], weekly["reset_since_observed"]), (0, True))

    def test_compressed_codex_logs_are_read(self):
        rows = [{"type": "token_usage_record", "timestamp": at("09:01:00"),
                 "payload": {"turn_id": "t1", "response_id": "r1", "model": "gpt-5.4",
                             "usage": {"input_tokens": 70, "cached_input_tokens": 0, "output_tokens": 1}}}]
        folder = self.codex / "2026" / "11" / "16"
        folder.mkdir(parents=True)
        (folder / "rollout-a.jsonl.zst").write_bytes(zstd_frame(lines(rows)))
        # A plain copy of the same log wins over the compressed one.
        (folder / "rollout-b.jsonl.zst").write_bytes(zstd_frame(b"not json\n"))
        (folder / "rollout-b.jsonl").write_bytes(lines([dict(rows[0], payload=dict(
            rows[0]["payload"], turn_id="t2", response_id="r2"))]))
        compiler = shutil.which("cc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("No C compiler to build the bundled decoder")
        decoder = self.root / "TrackerUnzstd"
        subprocess.run([compiler, "-O1", f"-I{VENDOR}", str(VENDOR / "zstddeclib.c"), str(VENDOR / "unzstd.c"),
                        "-o", str(decoder)], check=True, capture_output=True)
        with patch.dict(os.environ, {"TRACKER_UNZSTD": str(decoder)}):
            result = self.sync(provider="codex")
        self.assertEqual(result["files_read"], 2)
        self.assertEqual(sorted(row["input"] for row in self.usage().values()), [70, 70])
        # A damaged file is reported instead of stopping the import.
        (folder / "rollout-c.jsonl.zst").write_bytes(zstd_frame(b"x")[:-1])
        with patch.dict(os.environ, {"TRACKER_UNZSTD": str(decoder)}):
            result = self.sync(provider="codex")
        self.assertTrue(any("rollout-c" in error for error in result["source_errors"]))


if __name__ == "__main__":
    unittest.main()
