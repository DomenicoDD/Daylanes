import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from tracker import blocks, importers, pricing, store


def at(clock):
    return f"2026-11-16T{clock}Z"


def millis(clock):
    return int(datetime.fromisoformat(f"2026-11-16T{clock}+00:00").timestamp() * 1000)


def write_rows(file, rows):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def prompt(clock, text="Please fix the export"):
    return {"type": "user", "timestamp": at(clock), "sessionId": "s1", "message": {"role": "user", "content": text}}


def tool_result(clock):
    return {"type": "user", "timestamp": at(clock), "sessionId": "s1", "toolUseResult": {"stdout": ""},
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}}


def reply(clock, request, usage=None, **extra):
    usage = usage or {"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                      "output_tokens": 5}
    return {"type": "assistant", "timestamp": at(clock), "sessionId": "s1", "requestId": request,
            "cwd": "/work/app", "gitBranch": "main",
            "message": {"model": "claude-opus-4-6-20260205", "content": "", "usage": usage}, **extra}


CATALOG = [{
    "id": "anthropic/claude-opus-4.6", "canonical_slug": "anthropic/claude-4.6-opus-20260205",
    "pricing": {"prompt": "0.000005", "completion": "0.000025", "input_cache_read": "0.0000005",
                "input_cache_write": "0.00000625",
                "overrides": [{"min_prompt_tokens": 200000, "prompt": "0.00001", "completion": "0.0000375",
                               "input_cache_read": "0.000001"}]},
}]


class AgentTrackingTests(unittest.TestCase):
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

    def entries(self, kind):
        with store.database(self.db) as conn:
            return [dict(row) for row in conn.execute("SELECT * FROM entries WHERE kind = ? ORDER BY at", (kind,))]

    def test_claude_time_comes_from_the_conversation_when_logs_have_no_request_timings(self):
        write_rows(self.claude / "app" / "s1.jsonl", [
            prompt("09:00:00"), reply("09:01:00", "a"), tool_result("09:02:00"), reply("09:03:00", "b"),
            # The person answers 17 minutes later: their thinking time is not agent time.
            prompt("09:20:00"), reply("09:21:00", "c"), reply("09:22:00", "c"),
            # A tool ran for 8 minutes with no log line: the pause ends the span.
            tool_result("09:30:00"), reply("09:31:00", "d"),
            # Subagent replies are counted as tokens but not as extra time.
            reply("09:50:00", "e", isSidechain=True),
        ])
        self.sync()
        runtime = self.entries("runtime")
        self.assertEqual([(row["at"], row["millis"]) for row in runtime], [
            (millis("09:00:00"), 3 * 60000), (millis("09:20:00"), 2 * 60000), (millis("09:30:00"), 60000)])
        self.assertTrue(all(row["label"] == "active session estimate" and row["provider"] == "claude"
                            and row["session"] == "s1" and row["folder"] == "/work/app" for row in runtime))
        self.assertEqual(len(self.entries("usage")), 5)
        # Reading the file again keeps the same spans instead of adding new ones.
        self.assertEqual(self.sync(rescan=True)["files_read"], 1)
        self.assertEqual(len(self.entries("runtime")), 3)

    def test_claude_logs_are_read_from_every_config_folder(self):
        home = self.root / "home"
        with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": f"{self.root}/one, {self.root}/two"}):
            self.assertEqual(importers.roots()["claude"], [self.root / "one" / "projects", self.root / "two" / "projects"])
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME")}
        with patch.dict(os.environ, environment, clear=True), patch.object(Path, "home", return_value=home):
            self.assertEqual(importers.roots()["claude"],
                             [home / ".config" / "claude" / "projects", home / ".claude" / "projects"])
            (home / ".claude").mkdir(parents=True)
            (home / ".config").mkdir()
            (home / ".config" / "claude").symlink_to(home / ".claude")
            self.assertEqual(importers.roots()["claude"], [home / ".config" / "claude" / "projects"])

    def test_long_claude_requests_use_long_context_prices(self):
        big = {"input_tokens": 10, "cache_read_input_tokens": 250000, "cache_creation_input_tokens": 0,
               "output_tokens": 1000}
        small = {"input_tokens": 10, "cache_read_input_tokens": 150000, "cache_creation_input_tokens": 0,
                 "output_tokens": 1000}
        write_rows(self.claude / "app" / "s1.jsonl", [
            prompt("09:00:00"), reply("09:01:00", "big", big), reply("09:02:00", "small", small)])
        self.sync()
        with store.database(self.db) as conn:
            with patch.object(pricing, "fetch_models", return_value=CATALOG):
                pricing.refresh(conn)
            catalog = pricing.Catalog(conn)
            quotes = {row["id"]: catalog.quote(dict(row)) for row in conn.execute("SELECT * FROM entries WHERE kind = 'usage'")}
        # 10 × $10/M + 250k × $1/M + 1000 × $37.50/M, against base rates for the smaller request.
        self.assertEqual(quotes["claude:big:usage"], pricing.Decimal("0.2876"))
        self.assertEqual(quotes["claude:small:usage"], pricing.Decimal("0.10005"))

    def test_long_codex_requests_get_their_own_entries(self):
        def record(response, tokens):
            return {"type": "token_usage_record", "timestamp": at("09:01:00"),
                    "payload": {"turn_id": "t1", "response_id": response, "model": "gpt-test",
                                "usage": {"input_tokens": tokens, "cached_input_tokens": tokens // 2,
                                          "output_tokens": 100}}}

        meta = {"type": "session_meta", "timestamp": at("09:00:00"), "payload": {"id": "thread", "cwd": "/work/app"}}
        file = self.codex / "rollout.jsonl"
        with store.database(self.db) as conn:
            # What an earlier version stored: every request of the turn in one entry.
            store.create_project(conn, "Build", "Client", "billable", None)
            store.add_entry(conn, dict(id="codex:thread:t1:gpt-test:usage", kind="usage", provider="codex",
                                       at=millis("09:01:00"), model="gpt-test", input=999999, project="Build"))
        write_rows(file, [meta, record("r1", 300000), record("r2", 2000)])
        self.sync(provider="codex")
        usage = {row["id"]: row for row in self.entries("usage")}
        self.assertEqual(set(usage), {"codex:turn:t1:gpt-test:usage", "codex:response:r1:usage"})
        self.assertEqual(usage["codex:response:r1:usage"]["prompt_tokens"], 300000)
        # A project assigned to the combined entry carries over to the split one.
        self.assertEqual({row["project"] for row in usage.values()}, {"Build"})
        self.assertEqual(usage["codex:turn:t1:gpt-test:usage"]["input"] + usage["codex:turn:t1:gpt-test:usage"]["cached"], 2000)
        # With only long requests left in the turn, the old combined entry is removed rather than kept twice.
        write_rows(file, [meta, record("r1", 300000)])
        self.sync(provider="codex")
        self.assertEqual([(row["id"], row["project"]) for row in self.entries("usage")],
                         [("codex:response:r1:usage", "Build")])

    def test_usage_blocks_follow_five_hour_windows_with_burn_rate(self):
        with store.database(self.db) as conn:
            for clock, tokens in (("09:10:00", 1000), ("10:00:00", 1000), ("15:30:00", 600), ("15:50:00", 600)):
                store.add_entry(conn, dict(id=f"claude:{clock}:usage", kind="usage", provider="claude",
                                           at=millis(clock), model="claude-test", input=tokens))
            result = blocks.usage_blocks(conn, hours=12, now=millis("16:00:00"))
            active = blocks.usage_blocks(conn, hours=12, active_only=True, now=millis("16:00:00"))["blocks"]
        first, second = result["blocks"][1], result["blocks"][0]
        self.assertEqual((first["start"], first["end"], first["total_tokens"], first["active"]),
                         (millis("09:00:00"), millis("14:00:00"), 2000, False))
        self.assertEqual((second["start"], second["total_tokens"], second["active"]), (millis("15:00:00"), 1200, True))
        self.assertEqual(second["resets_in_minutes"], 240)
        self.assertEqual(second["burn_rate"]["tokens_per_minute"], 60)
        self.assertEqual(second["projection"]["total_tokens"], 1200 + 60 * 240)
        self.assertEqual(second["tokens_without_api_price"], 1200)
        self.assertEqual(active, [second])

    def test_usage_windows_keep_their_boundaries_when_the_period_is_short(self):
        with store.database(self.db) as conn:
            for hour in range(21):
                store.add_entry(conn, dict(id=f"codex:{hour}:usage", kind="usage", provider="codex",
                                           at=millis(f"{hour:02d}:00:00"), model="gpt-test", input=100))
            long = blocks.usage_blocks(conn, hours=24, active_only=True, now=millis("20:30:00"))["blocks"]
            short = blocks.usage_blocks(conn, hours=5, active_only=True, now=millis("20:30:00"))["blocks"]
        # Hourly use since midnight: windows 00-05, 05-10, 10-15, 15-20, then 20-01 is open.
        self.assertEqual([(block["start"], block["total_tokens"]) for block in long], [(millis("20:00:00"), 100)])
        self.assertEqual(short, long)


if __name__ == "__main__":
    unittest.main()
