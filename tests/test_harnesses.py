"""Each agent importer against a small log in the tool's own format (formats as ccusage documents them)."""

import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tracker import harnesses, importers, store

T0 = 1790000000000  # 2026-09-21T14:13:20Z
ISO = "2026-09-21T14:13:20.000Z"


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, (dict, list)):
        content = json.dumps(content)
    path.write_text(content, encoding="utf-8")
    return path


def lines(*rows):
    return "".join(json.dumps(row) + "\n" for row in rows)


def database(path, *statements):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as db:
        for statement in statements:
            if isinstance(statement, tuple):
                db.execute(*statement)
            else:
                db.execute(statement)
    return path


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def field(number, value):
    """Encode one protobuf field: ints as varints, bytes and str as length-delimited."""
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    value = value.encode() if isinstance(value, str) else value
    return varint(number << 3 | 2) + varint(len(value)) + value


def message(*fields):
    return b"".join(field(number, value) for number, value in fields)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.endswith(("_HOME", "_DIR", "_ROOT"))}
        environment["HOME"] = str(self.home)
        isolated = patch.dict(os.environ, environment, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)
        self.db = self.root / "ledger.sqlite3"

    def sync(self, provider):
        with store.database(self.db) as conn:
            result = importers.sync(conn, provider=provider, codex=self.root / "none", claude=self.root / "none",
                                    opencode=":memory:")
        self.assertEqual(result["source_errors"], [])
        return result

    def usage(self, provider):
        with store.database(self.db) as conn:
            return [dict(row) for row in conn.execute(
                "SELECT * FROM entries WHERE kind = 'usage' AND provider = ? ORDER BY at, id", (provider,))]

    def tokens(self, row):
        return row["input"], row["cached"], row["cache_write"], row["output"]

    def test_every_tool_is_registered(self):
        self.assertEqual({source.name for source in harnesses.file_sources()}, set(harnesses.NAMES))
        self.assertEqual(len(harnesses.NAMES), 17)
        self.assertEqual(set(importers.PROVIDERS), {"codex", "claude", "opencode", *harnesses.NAMES})

    def test_amp_prefers_the_usage_ledger_and_takes_cache_counts_from_messages(self):
        write(self.home / ".local/share/amp/threads/T-1.json", {
            "id": "T-1",
            "messages": [{"role": "assistant", "messageId": 3,
                          "usage": {"cacheCreationInputTokens": 40, "cacheReadInputTokens": 500}}],
            "usageLedger": {"events": [{"id": "e1", "timestamp": ISO, "model": "claude-sonnet-4-5",
                                        "tokens": {"input": 100, "output": 20}, "toMessageId": 3}]}})
        self.sync("amp")
        [row] = self.usage("amp")
        self.assertEqual(self.tokens(row), (100, 500, 40, 20))
        self.assertEqual((row["at"], row["session"], row["model"]), (T0, "T-1", "claude-sonnet-4-5"))

    def test_droid_session_totals_with_thinking_tokens(self):
        write(self.home / ".factory/sessions/p/abc.settings.json", {
            "model": "custom:Claude-Sonnet-4.5-[Proxy]", "providerLockTimestamp": ISO,
            "tokenUsage": {"inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 7, "cacheCreationTokens": 3,
                           "thinkingTokens": 4}})
        self.sync("droid")
        [row] = self.usage("droid")
        self.assertEqual((self.tokens(row), row["reasoning"], row["model"]), ((10, 7, 3, 9), 4, "claude-sonnet-4-5"))
        # The totals grow in place; reading again updates the same entry.
        write(self.home / ".factory/sessions/p/abc.settings.json", {
            "model": "claude-sonnet-4-5", "providerLockTimestamp": ISO,
            "tokenUsage": {"inputTokens": 20, "outputTokens": 5}})
        self.sync("droid")
        self.assertEqual([row["input"] for row in self.usage("droid")], [20])

    def test_codebuff_reads_openai_style_usage_without_counting_cache_twice(self):
        write(self.home / ".config/manicode/projects/app/chats/2026-09-21T14-13-20.000Z/chat-messages.json", [
            {"variant": "user", "content": "hi"},
            {"id": "m1", "variant": "ai", "metadata": {"model": "openai/gpt-5.4", "usage": {
                "promptTokens": 1000, "completionTokens": 50, "promptTokensDetails": {"cachedTokens": 800}}}}])
        self.sync("codebuff")
        [row] = self.usage("codebuff")
        self.assertEqual(self.tokens(row), (200, 800, 0, 50))
        self.assertEqual((row["at"], row["session"]), (T0, "manicode/app/2026-09-21T14-13-20.000Z"))

    def test_cline_extension_and_cli_records_with_recorded_costs(self):
        write(self.home / ".cline/data/tasks/t1/ui_messages.json", [
            {"ts": T0, "type": "say", "say": "api_req_started", "modelInfo": {"modelId": "claude-sonnet-4-5"},
             "text": json.dumps({"tokensIn": 100, "tokensOut": 25, "cacheReads": 10, "cacheWrites": 20, "cost": 0.002})},
            {"ts": T0 + 1, "type": "say", "say": "api_req_started", "text": json.dumps({"request": "in progress"})}])
        write(self.home / ".cline/data/sessions/s1/s1.messages.json", {"messages": [
            {"role": "assistant", "ts": T0 + 5, "id": "a", "modelInfo": {"id": "gpt-5.4"},
             "metrics": {"inputTokens": 100, "outputTokens": 5, "cacheReadTokens": 60, "cacheWriteTokens": 10}}]})
        self.sync("cline")
        task, cli = self.usage("cline")
        self.assertEqual((self.tokens(task), task["recorded_usd"], task["session"]), ((100, 10, 20, 25), "0.002", "task:t1"))
        # The CLI counts cache inside its input.
        self.assertEqual((self.tokens(cli), cli["session"]), ((30, 60, 10, 5), "cli:s1"))

    def test_hermes_sessions_use_the_actual_cost(self):
        database(self.home / ".hermes/state.db",
                 "CREATE TABLE sessions (id TEXT, model TEXT, billing_provider TEXT, started_at REAL, input_tokens INT,"
                 " output_tokens INT, cache_read_tokens INT, cache_write_tokens INT, reasoning_tokens INT,"
                 " estimated_cost_usd REAL, actual_cost_usd REAL, cwd TEXT)",
                 ("INSERT INTO sessions VALUES ('s1', 'gpt-5.4', 'openai', ?, 100, 50, 20, 0, 5, 0.25, 0.34, '/work/app')",
                  (T0 / 1000,)))
        self.sync("hermes")
        [row] = self.usage("hermes")
        self.assertEqual((self.tokens(row), row["reasoning"]), ((100, 20, 0, 55), 5))
        self.assertEqual((row["recorded_usd"], row["model"], row["folder"]), ("0.34", "openai/gpt-5.4", "/work/app"))

    def test_pi_counts_a_forked_session_s_copied_history_once(self):
        header = {"type": "session", "timestamp": ISO, "cwd": "/work/app"}
        call = {"type": "message", "timestamp": ISO, "message": {"role": "assistant", "model": "claude-sonnet-4-5",
                                                                 "usage": {"input": 10, "output": 5, "cacheRead": 100,
                                                                           "cacheWrite": 2, "cost": {"total": 0.01}}}}
        write(self.home / ".pi/agent/sessions/--work-app--/a.jsonl", lines(header, call))
        later = dict(call, timestamp="2026-09-21T15:00:00Z")
        write(self.home / ".pi/agent/sessions/--work-app--/b.jsonl", lines(dict(header, parentSession="a.jsonl"), call, later))
        write(self.home / ".pi/agent/sessions/--work-app--/subagent-artifacts/x.jsonl", lines(header, call))
        self.sync("pi")
        rows = self.usage("pi")
        self.assertEqual(len(rows), 2)
        self.assertEqual((self.tokens(rows[0]), rows[0]["recorded_usd"], rows[0]["folder"]),
                         ((10, 100, 2, 5), "0.01", "/work/app"))

    def test_openclaw_maps_agents_and_channels_to_folders_and_reads_the_database(self):
        agent = self.home / ".openclaw/agents/support"
        write(agent / "sessions/sessions.json", {"agent:support:telegram:dm:42": {"sessionId": "u1"}})
        event = {"type": "message", "id": "ev1", "timestamp": ISO, "message": {
            "role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-5",
            "usage": {"input": 10, "output": 5, "cacheRead": 7, "cacheWrite": 1, "totalTokens": 23,
                      "cost": {"total": 0.02}}}}
        write(agent / "sessions/u1.jsonl", lines({"type": "model_change", "provider": "openai", "modelId": "gpt-5.4"},
                                                  event))
        # An archived transcript, and the database a newer version migrated the same event into.
        write(agent / "sessions/u2.jsonl.deleted.1790000000", lines(dict(event, id="ev2")))
        database(agent / "agent/openclaw-agent.sqlite",
                 "CREATE TABLE transcript_events (session_id TEXT, seq INT, event_json TEXT, created_at INT)",
                 ("INSERT INTO transcript_events VALUES ('u1', 0, ?, ?)", (json.dumps(event), T0)))
        self.sync("openclaw")
        rows = {row["session"]: row for row in self.usage("openclaw")}
        self.assertEqual(set(rows), {"u1", "u2"})
        self.assertEqual((self.tokens(rows["u1"]), rows["u1"]["recorded_usd"]), ((10, 7, 1, 5), "0.02"))
        self.assertEqual(rows["u1"]["folder"], str((agent / "channels/telegram/dm/42").resolve()))
        self.assertEqual(rows["u2"]["folder"], str(agent.resolve()))
        self.assertEqual(rows["u1"]["model"], "anthropic/claude-sonnet-4-5")

    def test_goose_session_totals(self):
        database(self.home / ".local/share/goose/sessions/sessions.db",
                 "CREATE TABLE sessions (id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT,"
                 " total_tokens INT, input_tokens INT, output_tokens INT, accumulated_total_tokens INT,"
                 " accumulated_input_tokens INT, accumulated_output_tokens INT, working_dir TEXT)",
                 "INSERT INTO sessions VALUES ('g1', '{\"model_name\": \"gpt-5.4\"}', 'openai', '2026-09-21 14:13:20',"
                 " 10, 5, 5, 130, 100, 20, '/work/app')")
        self.sync("goose")
        [row] = self.usage("goose")
        self.assertEqual((self.tokens(row), row["reasoning"], row["at"], row["model"]),
                         ((100, 0, 0, 30), 10, T0, "openai/gpt-5.4"))

    def test_kilo_messages(self):
        data = {"id": "msg-1", "role": "assistant", "providerID": "anthropic", "modelID": "claude-sonnet-4-5",
                "time": {"created": T0}, "tokens": {"input": 100, "output": 50, "reasoning": 5,
                                                   "cache": {"read": 10, "write": 20}}, "cost": 0.02}
        database(self.home / ".local/share/kilo/kilo.db",
                 "CREATE TABLE message (id TEXT, session_id TEXT, data TEXT)",
                 ("INSERT INTO message VALUES ('msg-1', 's1', ?)", (json.dumps(data),)))
        self.sync("kilo")
        [row] = self.usage("kilo")
        self.assertEqual((self.tokens(row), row["recorded_usd"]), ((100, 10, 20, 55), "0.02"))

    def test_kimi_counts_turn_records_and_status_updates(self):
        write(self.home / ".kimi/config.json", {"model": "kimi-k2"})
        write(self.home / ".kimi/sessions/g/s1/wire.jsonl", lines(
            {"timestamp": T0 / 1000, "message": {"type": "StatusUpdate", "payload": {"message_id": "m1", "token_usage": {
                "input_other": 10, "output": 5, "input_cache_read": 100, "input_cache_creation": 2}}}}))
        write(self.home / ".kimi-code/sessions/w/s2/agents/a/wire.jsonl", lines(
            {"type": "usage.record", "usageScope": "turn", "model": "kimi-code/kimi-k2.6", "time": T0,
             "usage": {"inputOther": 7, "output": 3}},
            {"type": "usage.record", "usageScope": "session", "time": T0, "usage": {"inputOther": 70, "output": 30}}))
        self.sync("kimi")
        rows = {row["session"]: row for row in self.usage("kimi")}
        self.assertEqual((self.tokens(rows["s1"]), rows["s1"]["model"]), ((10, 100, 2, 5), "kimi-k2"))
        self.assertEqual((self.tokens(rows["s2"]), rows["s2"]["model"]), ((7, 0, 0, 3), "kimi-k2.6"))

    def test_qwen_counts_archived_chats_once(self):
        row = {"type": "assistant", "uuid": "u1", "timestamp": ISO, "sessionId": "s1", "model": "qwen3-coder-plus",
               "usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 50, "thoughtsTokenCount": 20,
                                 "cachedContentTokenCount": 600, "totalTokenCount": 1070}}
        write(self.home / ".qwen/projects/p/chats/a.jsonl", lines(row))
        write(self.home / ".qwen/projects/p/chats/archive/a.jsonl", lines(row))
        self.sync("qwen")
        [entry] = self.usage("qwen")
        self.assertEqual((self.tokens(entry), entry["reasoning"]), ((400, 600, 0, 70), 20))

    def test_copilot_usage_records_and_shutdown_intervals(self):
        write(self.home / ".copilot/session-state/old/events.jsonl", lines(
            {"type": "session.shutdown", "timestamp": ISO, "data": {"modelMetrics": {"claude-opus-4.7-1m": {
                "usage": {"inputTokens": 100, "outputTokens": 50, "cacheReadTokens": 10, "cacheWriteTokens": 20},
                "totalNanoAiu": 2_000_000_000}}}},
            {"type": "session.shutdown", "timestamp": "2026-09-21T15:00:00Z", "data": {"modelMetrics": {
                "claude-opus-4.7-1m": {"usage": {"inputTokens": 150, "outputTokens": 60, "cacheReadTokens": 10,
                                                 "cacheWriteTokens": 20}, "totalNanoAiu": 3_000_000_000}}}}))
        record = {"type": "session.usage_record", "id": "e1", "timestamp": ISO, "data": {"usage": {
            "model": "gpt-5.4", "inputTokens": 30, "outputTokens": 4, "cacheReadTokens": 10,
            "accounting": {"sourceSessionId": "new", "sequence": 1}, "copilotUsage": {"totalNanoAiu": 500_000_000}}}}
        write(self.home / ".copilot/session-state/new/events.jsonl", lines(record))
        write(self.home / ".copilot/session-state/other/events.jsonl", lines(record))
        self.sync("copilot")
        rows = self.usage("copilot")
        calls = [row for row in rows if ":call:" in row["id"]]
        self.assertEqual([(self.tokens(row), row["recorded_usd"]) for row in calls], [((20, 10, 0, 4), "0.005")])
        intervals = [row for row in rows if ":shutdown:" in row["id"]]
        self.assertEqual([(self.tokens(row), row["recorded_usd"], row["model"]) for row in intervals],
                         [((70, 10, 20, 50), "0.02", "claude-opus-4.7"), ((50, 0, 0, 10), "0.01", "claude-opus-4.7")])

    def test_gemini_messages_and_session_statistics(self):
        write(self.home / ".gemini/tmp/h/chats/session-1.json", {
            "sessionId": "g1", "startTime": ISO, "messages": [
                {"type": "user", "content": "hi"},
                {"type": "gemini", "id": "m1", "model": "gemini-3.1-pro", "timestamp": ISO,
                 "tokens": {"input": 1000, "output": 50, "cached": 400, "thoughts": 30, "tool": 0, "total": 1080}}]})
        write(self.home / ".gemini/tmp/h/chats/run.jsonl", lines(
            {"type": "result", "session_id": "g2", "timestamp": ISO,
             "stats": {"models": {"gemini-3-flash": {"tokens": {"prompt": 500, "candidates": 20, "cached": 100}}}}}))
        self.sync("gemini")
        rows = {row["session"]: row for row in self.usage("gemini")}
        # The total shows the message's input includes its cached prompt.
        self.assertEqual((self.tokens(rows["g1"]), rows["g1"]["reasoning"]), ((600, 400, 0, 80), 30))
        self.assertEqual(self.tokens(rows["g2"]), (400, 100, 0, 20))

    def test_antigravity_decodes_generation_metadata_and_merges_repeated_calls(self):
        stamp = message((1, T0 // 1000))
        usage = message((1, 1026), (2, 100), (3, 60), (4, 5), (5, 900), (9, 20), (10, 40), (11, "resp-1"))
        chat = message((4, usage), (17, message((2, usage))), (9, message((4, stamp))), (19, "Gemini 3.1 Pro (High)"))
        step = message((9, usage), (8, stamp))
        database(self.home / ".gemini/antigravity/conversations/c1.db",
                 "CREATE TABLE gen_metadata (idx INTEGER, data BLOB)", "CREATE TABLE steps (idx INTEGER, metadata BLOB)",
                 ("INSERT INTO gen_metadata VALUES (0, ?)", (message((1, chat)),)),
                 ("INSERT INTO steps VALUES (0, ?)", (step,)))
        self.sync("antigravity")
        [row] = self.usage("antigravity")
        self.assertEqual((self.tokens(row), row["reasoning"], row["at"]), ((100, 900, 5, 60), 20, T0))
        self.assertEqual(row["model"], "gemini-3.1-pro")

    def test_grok_completed_turns_with_recorded_cost(self):
        session = self.home / ".grok/sessions/%2Fwork%2Fapp/u1"
        write(session / "summary.json", {"info": {"id": "u1", "cwd": "/work/app"}, "current_model_id": "grok-4.5-build"})
        write(session / "updates.jsonl", lines(
            {"timestamp": T0 // 1000, "params": {"sessionId": "u1", "_meta": {"eventId": "e1"}, "update": {
                "sessionUpdate": "turn_completed", "usage": {
                    "inputTokens": 1000, "outputTokens": 50, "cachedReadTokens": 700, "cacheCreationTokens": 100,
                    "reasoningTokens": 20, "costUsdTicks": 1_500_000_000}}}},
            {"timestamp": T0 // 1000, "params": {"update": {"sessionUpdate": "agent_message_chunk"}}}))
        self.sync("grok")
        [row] = self.usage("grok")
        self.assertEqual((self.tokens(row), row["recorded_usd"], row["model"], row["folder"]),
                         ((200, 700, 100, 50), "0.15", "grok-4.5", "/work/app"))

    def test_zcode_completed_rows(self):
        database(self.home / ".zcode/cli/db/db.sqlite",
                 "CREATE TABLE model_usage (id TEXT, session_id TEXT, started_at INT, model_id TEXT, status TEXT,"
                 " input_tokens INT, output_tokens INT, cache_creation_input_tokens INT, cache_read_input_tokens INT,"
                 " provider_id TEXT)",
                 "CREATE TABLE session (id TEXT, directory TEXT)",
                 ("INSERT INTO model_usage VALUES ('r1', 's1', ?, 'GLM-5', 'completed', 1000, 30, 100, 600,"
                  " 'builtin:zai-coding-plan')", (T0,)),
                 ("INSERT INTO model_usage VALUES ('r2', 's1', ?, 'GLM-5', 'failed', 1000, 30, 0, 0, NULL)", (T0,)),
                 "INSERT INTO session VALUES ('s1', '/work/app')")
        self.sync("zcode")
        [row] = self.usage("zcode")
        self.assertEqual((self.tokens(row), row["model"], row["folder"]), ((300, 600, 100, 30), "z-ai/glm-5", "/work/app"))

    def test_deepseek_harness_forks_count_only_their_own_requests(self):
        folder = self.home / ".dsh/sessions/p/session-1"
        request = {"type": "assistant/message", "seq": 3, "time": T0,
                   "data": {"usage": {"inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 90}}}
        write(folder / "session.jsonl", lines({"type": "session", "id": "old"}, request))
        write(folder / "session.v2.jsonl", lines(
            {"type": "session", "id": "session-1", "cwd": "/work/app", "isSeeded": True},
            {"type": "request/header", "data": {"header": {"config": {"provider": "deepseek-official",
                                                                      "model": "deepseek-v4"}}}},
            request,
            {"type": "session/end-seed", "data": {"inherited": True}},
            dict(request, seq=7, data={"stream": [{"type": "chunk", "chunk": {"type": "usage", "usage": {
                "inputTokens": 20, "outputTokens": 2}}}]})))
        self.sync("dsh")
        [row] = self.usage("dsh")
        self.assertEqual((self.tokens(row), row["model"], row["session"]), ((20, 0, 0, 2), "deepseek-v4", "session-1"))


if __name__ == "__main__":
    unittest.main()
