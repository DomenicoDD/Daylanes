import json
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from tracker import importers, reports, store


STAMP = store.parse_at("2026-11-16T09:00:00Z")
WINDOW = {"start": "2026-11-16", "end": "2026-11-17"}


class OpenCodeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.db = self.root / "ledger.sqlite3"
        self.data = self.root / "xdg" / "opencode"
        self.data.mkdir(parents=True)
        self.source = self.data / "opencode.db"
        self.folder = str(self.root / "project")

    def test_imports_committed_wal_updates_and_keeps_project_assignments(self):
        with closing(sqlite3.connect(self.source)) as source:
            source.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER);
                CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            """)
            source.execute("INSERT INTO session VALUES ('s1', ?, ?)", (self.folder, STAMP - 1000))
            record = {"role": "assistant", "providerID": "openrouter", "modelID": "anthropic/claude-opus-4.6",
                      "tokens": {"input": 100, "output": 30, "reasoning": 20, "cache": {"read": 70, "write": 40}},
                      "time": {"completed": STAMP + 3000}, "content": "Private prompt"}
            source.execute("INSERT INTO message VALUES ('m1', 's1', ?, ?)", (STAMP, json.dumps(record)))
            source.commit()
            with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.data.parent), "OPENCODE_DB": ""}):
                with store.database(self.db) as conn:
                    stats = importers.sync(conn, codex=self.root / "codex", claude=self.root / "claude")
                    self.assertEqual(stats["events_processed"], 2)
                    self.assertEqual(stats["directories"]["opencode"], [str(self.source)])
                    store.create_project(conn, "Delivery", "Client", "billable", None)
                    store.assign(conn, "harness:opencode:m1", "Delivery")
                record["tokens"]["output"] = 45
                source.execute("UPDATE message SET data = ? WHERE id = 'm1'", (json.dumps(record),))
                source.commit()
                with store.database(self.db) as conn:
                    importers.sync(conn, provider="opencode")
                    result = reports.report(conn, project="Delivery", **WINDOW)["totals"]["agents"]["opencode"]
                    self.assertEqual(result["tokens"], {"input": 100, "cached": 70, "cache_write": 40, "output": 65})
                    rows = conn.execute("SELECT * FROM entries ORDER BY kind").fetchall()
                    self.assertEqual(len(rows), 2)
                    self.assertEqual(rows[0]["millis"], 3000)
                    self.assertEqual(rows[1]["model"], "anthropic/claude-opus-4.6")
                    self.assertNotIn("Private prompt", repr([dict(row) for row in rows]))

    def test_combines_upgraded_history_and_skips_copied_messages(self):
        with closing(sqlite3.connect(self.source)) as source, source:
            source.executescript("""
                CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER);
                CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER);
                CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
            """)
            old = STAMP - 90 * 86400000
            source.execute("INSERT INTO session VALUES ('original', ?, ?)", (self.folder, old))
            source.execute("INSERT INTO session_v2 VALUES ('original', ?, ?)", (self.folder, old))
            source.execute("INSERT INTO session_v2 VALUES ('fork', ?, ?)", (self.folder, STAMP + 100))
            legacy = {"role": "assistant", "modelID": "gpt-test", "providerID": "openai",
                      "tokens": {"input": 4, "output": 6, "reasoning": 2, "total": 10}}
            source.executemany("INSERT INTO message VALUES (?, 'original', ?, ?)", [
                ("legacy", old, json.dumps(legacy)), ("migrated", STAMP, json.dumps(legacy)),
            ])
            native = json.dumps({"model": {"id": "gemini-test", "providerID": "google"}, "tokens": {"input": 60}})
            source.executemany("INSERT INTO session_message VALUES (?, ?, 'assistant', ?, ?)", [
                ("migrated", "original", STAMP, native), ("copy", "fork", STAMP, native),
                ("new", "fork", STAMP + 200, native), ("damaged", "original", STAMP, "{invalid"),
            ])
        with store.database(self.db) as conn, patch.object(importers.time, "time", return_value=STAMP / 1000 + 1):
            status = importers.sync(conn, provider="opencode", opencode=self.source, recent_days=64)
            self.assertEqual(status["source_errors"], [])
            self.assertEqual(status["events_processed"], 2)
            usage = reports.report(conn, **WINDOW)["totals"]["agents"]["opencode"]
            self.assertEqual(usage["models"]["openai/gpt-test"]["output"], 6)
            self.assertEqual(usage["models"]["google/gemini-test"]["input"], 60)
        with store.database(self.db) as conn:
            importers.sync(conn, provider="opencode", opencode=self.source)
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0], 3)
