import io
import json
import os
import shutil
import subprocess
import re
import sqlite3
import time
from collections import defaultdict
from contextlib import closing
from functools import lru_cache
from pathlib import Path

from .store import add_entry, parse_at, required, set_setting, setting, task_from_branch

TOKEN_FIELDS = ("input", "cached", "cache_write", "output")
# Every agent Tracker reads on its own; tracker/harnesses.py has all but the first three.
PROVIDERS = ("codex", "claude", "opencode", "amp", "droid", "codebuff", "cline", "hermes", "pi", "openclaw",
             "goose", "kilo", "kimi", "qwen", "copilot", "gemini", "antigravity", "grok", "zcode", "dsh")
# Pauses longer than this end an agent's active span (the gap ccusage and similar tools use).
IDLE_GAP_MILLIS = 5 * 60 * 1000
# Codex requests at least this large keep their own entry, so long-context prices apply to them alone.
# The smallest long-context threshold in the OpenRouter catalog is 100k tokens.
LONG_PROMPT_TOKENS = 100_000


def obj(value):
    return value if isinstance(value, dict) else {}


def string(value):
    return value if isinstance(value, str) and value.strip() else None


def harness_id(value):
    value = required(value, "Harness")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", value):
        raise ValueError("Use a harness ID such as opencode or my-agent")
    return value


def number(value):
    return value if type(value) is int and 0 <= value <= 10**12 else 0


@lru_cache(maxsize=2048)
def canonical_folder(value):
    if value and Path(value).is_absolute():
        try:
            return str(Path(value).resolve())
        except (RuntimeError, OSError):
            return value
    return None


def normalized_usage(raw, provider):
    counts = number(raw.get("input_tokens"))
    output = number(raw.get("output_tokens"))
    if provider == "claude":
        return counts, number(raw.get("cache_read_input_tokens")), number(raw.get("cache_creation_input_tokens")), output
    cached = min(counts, number(raw.get("cached_input_tokens")))
    writes = min(counts - cached, number(raw.get("cache_write_input_tokens")))
    return counts - cached - writes, cached, writes, output


class UnreadableSource(Exception):
    """A log that cannot be read yet: compressed without a decoder, or still being written."""


def zstd_decoder():
    """How to read Codex's compressed .jsonl.zst logs on this machine, best first."""
    configured = os.getenv("TRACKER_UNZSTD")
    # In the app bundle the decoder sits in Contents/MacOS, next to the engine in Contents/Resources.
    bundled = Path(__file__).resolve().parents[2] / "MacOS" / "TrackerUnzstd"
    for helper in (configured, str(bundled), shutil.which("zstd")):
        if helper and os.access(helper, os.X_OK):
            arguments = [helper] if Path(helper).name != "zstd" else [helper, "-dcq"]
            return lambda path: subprocess.run([*arguments, str(path)], capture_output=True, timeout=600)
    for module in ("compression.zstd", "zstandard"):
        try:
            library = __import__(module, fromlist=["decompress"])
        except ImportError:
            continue
        if module == "zstandard":
            return lambda path: subprocess.CompletedProcess(
                [], 0, library.ZstdDecompressor().decompressobj().decompress(path.read_bytes()), b"")
        return lambda path: subprocess.CompletedProcess([], 0, library.decompress(path.read_bytes()), b"")
    return None


def read_lines(path):
    if not path.name.endswith((".zst", ".zstd")):
        with path.open("rb") as source:
            yield from source
        return
    decoder = zstd_decoder()
    if decoder is None:
        raise UnreadableSource("No zstd decoder: build the app with bin/build-desktop or install zstd")
    try:
        result = decoder(path)
    except Exception as error:  # noqa: BLE001 - a corrupt file must not stop the whole import
        raise UnreadableSource(f"{path.name}: {error}") from None
    if result.returncode != 0 and not result.stdout:
        raise UnreadableSource(f"{path.name}: {result.stderr.decode(errors='replace').strip() or 'decoding failed'}")
    # A log still being written can end inside a frame: the complete records before it count.
    yield from io.BytesIO(result.stdout)


def json_records(path, stats):
    for line in read_lines(path):
        try:
            row = json.loads(line)
        except (ValueError, UnicodeError):
            if line.endswith(b"\n"):
                stats["ignored_lines"] += 1
            continue
        if isinstance(row, dict):
            yield row


def metadata(provider, session, folder, branch):
    return dict(
        provider=provider, session=session, folder=canonical_folder(folder),
        branch=branch, task=task_from_branch(branch),
    )


CODEX_TIERS = {"priority": "fast", "fast": "fast", "flex": "flex", "ultrafast": "ultrafast",
               "default": None, "standard": None}


def real_turn(key):
    """Codex turn IDs are unique across logs, so a forked log's copy of a turn lands on the same entry."""
    return bool(key) and key != "session" and not key.startswith("at-")


def codex_entries(records, file_id):
    session, folder, branch, model, turn, turn_start, tier = file_id, None, None, None, None, None, None
    forked_at = None
    turns = {}
    legacy = defaultdict(list)
    modern = defaultdict(dict)
    last_totals = None
    limits = None

    for row in records:
        kind = row.get("type")
        payload = obj(row.get("payload"))
        at = parse_at(row.get("timestamp"))
        if kind == "session_meta":
            session = string(payload.get("id")) or string(payload.get("session_id")) or session
            folder = string(payload.get("cwd")) or folder
            branch = string(obj(payload.get("git")).get("branch")) or branch
            if string(payload.get("forked_from_id")):
                # A fork starts by copying its parent's history, written in one burst at the fork time.
                forked_at = parse_at(payload.get("timestamp")) or at
        elif kind == "turn_context":
            turn = string(payload.get("turn_id")) or turn
            folder = string(payload.get("cwd")) or folder
            branch = string(obj(payload.get("git")).get("branch")) or branch
            model = string(payload.get("model")) or model
        elif kind == "token_usage_record":
            response = string(payload.get("response_id"))
            raw = obj(payload.get("usage"))
            observed_at = at if at is not None else turn_start
            if response and raw and observed_at is not None:
                key = string(payload.get("turn_id")) or turn or "session"
                reported_model = string(payload.get("model")) or model
                modern[key].setdefault(response, (observed_at, reported_model, folder, branch, raw, tier))
        elif kind == "event_msg":
            event = payload.get("type")
            if event == "thread_settings_applied":
                settings = obj(payload.get("thread_settings"))
                if "service_tier" in settings:
                    tier = CODEX_TIERS.get(string(settings.get("service_tier")))
            elif event in ("task_started", "turn_started"):
                turn_start = parse_at(payload.get("started_at"))
                if turn_start is None:
                    turn_start = at
                turn = string(payload.get("turn_id")) or f"at-{turn_start}"
            elif event in ("task_complete", "turn_complete", "turn_aborted"):
                key = string(payload.get("turn_id")) or turn
                start = parse_at(payload.get("started_at"))
                if start is None:
                    start = turn_start
                end = parse_at(payload.get("completed_at"))
                if end is None:
                    end = at
                duration = number(payload.get("duration_ms"))
                if start is not None and not duration and end is not None:
                    duration = max(0, end - start)
                if duration and start is not None and key:
                    turns[key] = dict(
                        id=f"codex:turn:{key}:runtime" if real_turn(key) else f"codex:{session}:{key}:runtime",
                        kind="runtime", at=start, millis=duration, model=model, label="turn elapsed",
                        **metadata("codex", session, folder, branch),
                    )
                    if real_turn(key):
                        turns[f"{key}:old"] = dict(id=f"codex:{session}:{key}:runtime", remove=True)
                turn = None
                turn_start = None
            elif event == "token_count":
                if isinstance(payload.get("rate_limits"), dict) and at is not None:
                    limits = dict(payload["rate_limits"], observed_at=at)
                info = obj(payload.get("info"))
                totals = obj(info.get("total_token_usage"))
                if totals and totals == last_totals:
                    continue
                latest = obj(info.get("last_token_usage"))
                if not latest and totals and last_totals:
                    latest = {k: max(0, number(v) - number(last_totals.get(k))) for k, v in totals.items()}
                if totals:
                    last_totals = totals
                if forked_at is not None and at is not None and abs(at - forked_at) <= 2000:
                    continue  # the parent's usage, replayed into the fork
                if at is not None and latest:
                    if info.get("last_usage_includes_reasoning") is False:
                        latest = dict(latest, output_tokens=number(latest.get("output_tokens")) +
                                      number(latest.get("reasoning_output_tokens")))
                    key = turn or "session"
                    legacy[key].append((at, model, folder, branch, latest, tier))

    for key in modern.keys() | legacy.keys():
        observations = modern[key].items() if key in modern else ((None, row) for row in legacy[key])
        by_model = {}
        long_requests = []
        old_ids = set()
        for response, (at, model, folder, branch, raw, request_tier) in observations:
            counts = normalized_usage(raw, "codex")
            if not any(counts):
                continue
            prompt = sum(counts[:3])
            label = model or "unknown"
            old_turn_id = f"codex:{session}:{key}:{label}:usage"
            turn_id = (f"codex:turn:{key}:{label}" if real_turn(key) else old_turn_id[:-len(":usage")]) \
                + (f":{request_tier}" if request_tier else "") + ":usage"
            detail = dict(reasoning=number(raw.get("reasoning_output_tokens")), tier=request_tier,
                          **metadata("codex", session, folder, branch))
            # Both the combined entry an earlier version wrote and this turn's own: whichever ends up
            # with no short requests is removed below.
            old_ids.update((old_turn_id, turn_id))
            if prompt >= LONG_PROMPT_TOKENS:
                request = response or f"at-{at}"
                old_ids.add(f"codex:{session}:{key}:{request}:{label}:usage")
                long_requests.append(dict(
                    id=f"codex:response:{response}:usage" if response
                    else f"codex:{session}:{key}:{request}:{label}:usage",
                    kind="usage", at=at, model=model, prompt_tokens=prompt, inherit_project=old_turn_id,
                    **detail, **dict(zip(TOKEN_FIELDS, counts))))
                continue
            entry = by_model.get(turn_id)
            if entry is None:
                entry = by_model[turn_id] = dict(
                    id=turn_id, kind="usage", at=at, model=model, prompt_tokens=0, inherit_project=old_turn_id,
                    **dict(detail, reasoning=0), **dict.fromkeys(TOKEN_FIELDS, 0))
            entry["prompt_tokens"] = max(entry["prompt_tokens"], prompt)
            entry["reasoning"] += detail["reasoning"]
            for field, count in zip(TOKEN_FIELDS, counts):
                entry[field] += count
        # New entries first, so they take over a project assigned to an entry an earlier version wrote
        # (per log, so forks counted their parent's turns twice), then remove those old entries.
        yield from long_requests
        yield from by_model.values()
        kept = {entry["id"] for entry in (*long_requests, *by_model.values())}
        for old in sorted(old_ids - kept):
            yield dict(id=old, remove=True)
    yield from (entry for entry in turns.values() if not entry.get("remove"))
    yield from (entry for entry in turns.values() if entry.get("remove"))
    if limits is not None:
        yield dict(kind="rate_limits", provider="codex", limits=limits)


def human_prompt(row):
    """A message the person typed, as opposed to a tool result or a note Claude Code adds itself."""
    if row.get("isMeta") or row.get("isCompactSummary") or row.get("toolUseResult") is not None:
        return False
    content = obj(row.get("message")).get("content")
    if isinstance(content, list):
        return not any(isinstance(part, dict) and part.get("type") == "tool_result" for part in content)
    return isinstance(content, str)


def active_spans(events):
    """Spans the agent was working: from a prompt through its replies and tool calls, until the next
    prompt or a pause longer than IDLE_GAP_MILLIS. events are (at, starts_turn, context) in log order."""
    span = None
    for at, starts_turn, context in sorted(events, key=lambda event: event[0]):
        if span and not starts_turn and at - span[1] <= IDLE_GAP_MILLIS:
            span[1] = at
            span[2] = context or span[2]
            continue
        if span and span[1] > span[0]:
            yield span
        span = [at, at, context]
    if span and span[1] > span[0]:
        yield span


def claude_entries(records, file_id):
    request_starts = {}
    responses = {}
    advisors = {}
    activity = []  # (at, starts_turn, context) of the main conversation, for spans when no request timings exist
    for row in records:
        kind = row.get("type")
        at = parse_at(row.get("timestamp"))
        if at is None:
            continue
        if kind == "user" and not row.get("isSidechain"):
            activity.append((at, human_prompt(row), None))
        elif kind == "api-request" and string(row.get("id")):
            request_starts[row["id"]] = at
        elif kind in ("assistant", "progress"):
            if kind == "assistant":
                message, wrapper = obj(row.get("message")), row
            else:
                # Subagent progress wraps the subagent's own assistant message.
                wrapper = obj(obj(row.get("data")).get("message"))
                message = obj(wrapper.get("message"))
                if message.get("role") != "assistant":
                    continue
            model = string(message.get("model"))
            raw = obj(message.get("usage"))
            message_id = string(message.get("id"))
            key = string(wrapper.get("requestId")) or string(row.get("requestId")) or message_id or string(row.get("uuid"))
            if not raw or not key or (model and model.startswith("<")):
                continue
            counts = normalized_usage(raw, "claude")
            if not any(counts):
                continue
            session = string(row.get("sessionId")) or file_id
            folder = string(row.get("cwd"))
            branch = string(row.get("gitBranch"))
            context = metadata("claude", session, folder, branch)
            sidechain = bool(row.get("isSidechain")) or kind == "progress"
            if not sidechain:
                activity.append((at, False, (session, model, context)))
            start = request_starts.get(string(row.get("requestRef")))
            detail = claude_detail(raw, row)
            existing = responses.get(key)
            if existing is not None:
                previous, previous_start, previous_at = existing
                if start is None:
                    start = previous_start
                effective_at = max(at, previous_at)
                for field, count in zip(TOKEN_FIELDS, counts):
                    previous[field] = max(previous[field], count)
                for field in ("cache_write_1h", "reasoning", "web_searches"):
                    previous[field] = max(previous[field], detail[field])
                previous["tier"] = previous["tier"] or detail["tier"]
                previous["recorded_usd"] = previous["recorded_usd"] or detail["recorded_usd"]
                previous["replica"] = int(previous["replica"] and sidechain)
                previous["prompt_tokens"] = sum(previous[field] for field in TOKEN_FIELDS[:3])
                responses[key] = previous, start, effective_at
            else:
                entry = dict(id=f"claude:{key}:usage", kind="usage", at=at, model=model,
                             prompt_tokens=sum(counts[:3]), **dict(zip(TOKEN_FIELDS, counts)), **context,
                             **detail, dedupe_key=message_id if str(message_id or "").startswith(("msg_", "resp_")) else None,
                             replica=int(sidechain))
                responses[key] = entry, start, at
            # The advisor model's own calls are listed inside the response and billed at its rates.
            for index, iteration in enumerate(raw.get("iterations") or ()):
                iteration = obj(iteration)
                if iteration.get("type") != "advisor_message":
                    continue
                advisor = normalized_usage(iteration, "claude")
                if any(advisor):
                    advisors[f"claude:{key}:advisor:{index}:usage"] = dict(
                        id=f"claude:{key}:advisor:{index}:usage", kind="usage", at=at,
                        model=string(iteration.get("model")) or string(row.get("advisorModel")) or model,
                        prompt_tokens=sum(advisor[:3]), **dict(zip(TOKEN_FIELDS, advisor)), **context,
                        **claude_detail(iteration, {}), replica=int(sidechain))
    if not request_starts:
        # Claude Code logs usually carry no request timings, so measure time from the conversation itself.
        for start, end, context in active_spans(activity):
            if context is None:
                continue
            session, model, metadata_fields = context
            yield dict(id=f"claude:{session}:{start}:runtime", kind="runtime", at=start, millis=end - start,
                       model=model, label="active session estimate", **metadata_fields,
                       **dict.fromkeys(TOKEN_FIELDS, 0))
    for entry, start, end in responses.values():
        if start is not None and end > start:
            usage_id = entry["id"]
            yield dict(
                entry, id=usage_id[:-len("usage")] + "runtime", kind="runtime",
                at=start, millis=end - start, label="request window estimate",
                **dict.fromkeys(TOKEN_FIELDS, 0), **NO_DETAIL,
            )
        yield entry
    yield from advisors.values()


NO_DETAIL = dict(cache_write_1h=0, reasoning=0, web_searches=0, tier=None, recorded_usd=None,
                 dedupe_key=None, replica=0, prompt_tokens=None)


def claude_detail(raw, row):
    """Billing detail of one Claude response beyond the four token counts."""
    creation = obj(raw.get("cache_creation"))
    cost = row.get("costUSD")
    return dict(
        cache_write_1h=min(number(raw.get("cache_creation_input_tokens")), number(creation.get("ephemeral_1h_input_tokens"))),
        reasoning=number(obj(raw.get("output_tokens_details")).get("thinking_tokens")),
        web_searches=number(obj(raw.get("server_tool_use")).get("web_search_requests")),
        tier="fast" if raw.get("speed") == "fast" else None,
        recorded_usd=str(cost) if type(cost) in (int, float) and cost >= 0 else None,
    )


def claude_homes():
    """Claude Code keeps its logs in ~/.config/claude (newer) or ~/.claude (older), and CLAUDE_CONFIG_DIR
    may name one or more other folders, separated by commas."""
    configured = [part.strip() for part in os.getenv("CLAUDE_CONFIG_DIR", "").split(",") if part.strip()]
    if configured:
        return [Path(part).expanduser() for part in configured]
    config = Path(os.getenv("XDG_CONFIG_HOME") or Path.home() / ".config").expanduser()
    return [config / "claude", Path.home() / ".claude"]


def unique_paths(paths):
    seen = set()
    for path in paths:
        key = os.path.realpath(path)
        if key not in seen:
            seen.add(key)
            yield path


def codex_homes():
    configured = [part.strip() for part in os.getenv("CODEX_HOME", "").split(",") if part.strip()]
    return [Path(part).expanduser() for part in configured] or [Path.home() / ".codex"]


def roots(codex=None, claude=None):
    codex_dirs = (home / folder for home in codex_homes() for folder in ("sessions", "archived_sessions"))
    return {
        "codex": [Path(codex).expanduser()] if codex else list(unique_paths(codex_dirs)),
        "claude": [Path(claude).expanduser()] if claude else list(unique_paths(home / "projects" for home in claude_homes())),
    }


def opencode_databases(path=None):
    data = Path(os.getenv("XDG_DATA_HOME") or Path.home() / ".local" / "share").expanduser() / "opencode"
    configured = path or os.getenv("OPENCODE_DB")
    if configured:
        if str(configured) == ":memory:":
            return []
        database = Path(configured).expanduser()
        return [data / database if path is None else database]
    return [data / "opencode.db", *sorted(data.glob("opencode-*.db"))]


def opencode_rows(db, since):
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    layouts = []
    if {"message", "session"} <= tables:
        layouts.append(("message", "session", "json_extract(m.data, '$.role') = 'assistant'",
                        "$.modelID", "$.providerID"))
    if "session_message" in tables:
        # Recent 1.x builds also ship the projection, attached to the legacy session table.
        sessions = "session_v2" if "session_v2" in tables else "session"
        if sessions in tables:
            layouts.append(("session_message", sessions, "m.type IN ('assistant', 'compaction')",
                            "$.model.id", "$.model.providerID"))
    if not layouts:
        raise ValueError("Unrecognized OpenCode database schema")
    for messages, sessions, condition, model, provider in layouts:
        # Interpolated identifiers and JSON paths come only from the layouts above.
        # Forks copy earlier messages with their original creation times.
        yield from db.execute(f"""
            SELECT m.id, m.session_id, m.time_created, s.directory,
                   json_extract(m.data, ?) AS model,
                   json_extract(m.data, ?) AS model_provider,
                   json_extract(m.data, '$.path.cwd') AS cwd,
                   json_extract(m.data, '$.tokens') AS tokens,
                   json_extract(m.data, '$.time.streamed') AS streamed,
                   json_extract(m.data, '$.time.completed') AS completed
            FROM {messages} AS m JOIN {sessions} AS s ON s.id = m.session_id
            WHERE m.time_created >= ? AND m.time_created >= s.time_created
                AND CASE WHEN json_valid(m.data) THEN ({condition}) AND json_type(m.data, '$.tokens') = 'object' END
        """, (model, provider, since))


def opencode_entries(path, since):
    # Read committed WAL data from a snapshot without writing to OpenCode's database.
    uri = path.resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        for row in opencode_rows(db, since):
            tokens = obj(json.loads(row["tokens"]))
            cache = obj(tokens.get("cache"))
            counts = dict(input=number(tokens.get("input")), cached=number(cache.get("read")),
                          cache_write=number(cache.get("write")), output=number(tokens.get("output")))
            # Older records can include reasoning in output. Honor the reported total when it matches.
            if tokens.get("total") != sum(counts.values()):
                counts["output"] += number(tokens.get("reasoning"))
            if not any(counts.values()):
                continue
            model = string(row["model"])
            provider = string(row["model_provider"])
            if model and provider and "/" not in model:
                model = f"{provider}/{model}"
            folder = string(row["cwd"]) or string(row["directory"])
            context = metadata("opencode", row["session_id"], folder, None)
            at = row["time_created"]
            yield dict(id=f"harness:opencode:{row['id']}", kind="usage", at=at, model=model,
                       prompt_tokens=counts["input"] + counts["cached"] + counts["cache_write"], **counts, **context)
            end = row["streamed"] or row["completed"]
            if type(end) is int and 0 < end - at <= 10**12:
                yield dict(id=f"opencode:{row['id']}:runtime", kind="runtime", at=at, model=model,
                           millis=end - at, label="request window estimate", **context)


def sync_opencode(conn, stats, path, since):
    databases = [db for db in opencode_databases(path) if db.is_file()]
    stats["directories"]["opencode"] = [str(db) for db in databases]
    if path and str(path) != ":memory:" and not databases:
        stats["source_errors"].append(f"OpenCode database not found at {path}")
    seen = set()
    for db in databases:
        try:
            entries = list(opencode_entries(db, since))
        except (OSError, sqlite3.Error, ValueError) as error:
            stats["source_errors"].append(f"Could not read OpenCode history in {db.name}: {error}")
            continue
        stats["files_read"] += 1
        for entry in entries:
            if entry["id"] in seen:
                continue
            seen.add(entry["id"])
            add_entry(conn, entry, refresh=True)
            stats["events_processed"] += 1


def import_harness(conn, harness, source):
    """Read normalized usage from any harness adapter; store only ledger fields."""
    harness = harness_id(harness)
    if harness in ("codex", "claude"):
        raise ValueError("Use sync for Codex or Claude Code history")
    processed = 0
    for line, raw in enumerate(source, 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
            if not isinstance(row, dict):
                raise ValueError("Expected a usage object")
            event = required(row.get("id"), "Event ID")
            model = required(row.get("model"), "Model")
            at = parse_at(row.get("timestamp"))
            if at is None:
                raise ValueError("Provide an ISO timestamp or Unix seconds")
            counts = {field: row.get(field, 0) for field in TOKEN_FIELDS}
            if any(type(count) is not int or not 0 <= count <= 10**12 for count in counts.values()) or not any(counts.values()):
                raise ValueError("Provide nonnegative integer token counts and at least one token")
        except ValueError as error:
            raise ValueError(f"Line {line}: {error}") from None
        branch = string(row.get("branch"))
        add_entry(conn, dict(id=f"harness:{harness}:{event}", at=at, kind="usage", model=model, **counts,
                            prompt_tokens=counts["input"] + counts["cached"] + counts["cache_write"],
                            **metadata(harness, string(row.get("session")), string(row.get("folder")), branch)),
                  refresh=True)
        processed += 1
    return {"harness": harness, "events_processed": processed}


def transcript_id(path):
    name = path.name
    for suffix in (".zst", ".jsonl"):
        name = name.removesuffix(suffix)
    return name


def transcript_files(directories):
    """Every transcript once. Codex compresses older logs (.jsonl.zst); when both copies of a log
    exist the plain one is newer, and a log in sessions/ wins over its copy in archived_sessions/."""
    chosen = {}
    for directory in directories:
        if not directory.is_dir():
            continue
        found = [path for pattern in ("*.jsonl", "*.jsonl.zst") for path in directory.rglob(pattern)]
        for path in sorted(found, key=lambda path: (path.name.endswith(".zst"), str(path))):
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(directory).with_name(transcript_id(path))
            chosen.setdefault((directory.parent, str(relative)), path)
    return sorted(chosen.values())


def signature(stat):
    return f"{stat.st_size}:{stat.st_mtime_ns}:{stat.st_ino}"


def source_signature(source, path):
    """A database's committed changes can sit in its write-ahead log, which the main file's size and
    time do not show."""
    stamp = signature(path.stat())
    if getattr(source, "database", False):
        wal = path.with_name(path.name + "-wal")
        if wal.exists():
            stamp += "+" + signature(wal.stat())
    return stamp


# Raise when an importer change should apply to history that is already imported: the next sync
# then reads every log again, once.
IMPORTER_VERSION = 3


class FileSource:
    """A tool that keeps its history in files: where they are and how to read one."""

    def __init__(self, name, directories, read, files=None):
        self.name, self.directories, self.read = name, directories, read
        self.files = files or (lambda: transcript_files(directories))


def file_sources(codex=None, claude=None):
    found = roots(codex, claude)
    readers = {"codex": codex_entries, "claude": claude_entries}
    sources = [FileSource(name, found[name],
                          lambda path, stats, reader=readers[name]: reader(json_records(path, stats), transcript_id(path)))
               for name in ("codex", "claude")]
    from . import harnesses  # noqa: PLC0415 - harnesses build on this module
    return sources + harnesses.file_sources()


def store_entries(conn, entries):
    for entry in entries:
        if entry.get("remove"):
            conn.execute("DELETE FROM entries WHERE id = ?", (entry["id"],))
            continue
        if entry.get("kind") == "rate_limits":
            remember_limits(conn, entry["provider"], entry["limits"])
            continue
        entry = dict(entry)
        source = entry.pop("inherit_project", None)
        if source:
            assigned = conn.execute("SELECT project FROM entries WHERE id = ?", (source,)).fetchone()
            if assigned and assigned["project"]:
                entry["project"] = assigned["project"]
        add_entry(conn, entry, refresh=True)


def remember_limits(conn, provider, limits):
    """Keep the newest plan-limit snapshot a tool logged (Codex writes its 5-hour and weekly windows)."""
    key = f"{provider}_rate_limits"
    previous = json.loads(setting(conn, key, "{}"))
    if limits.get("observed_at", 0) >= previous.get("observed_at", 0):
        set_setting(conn, key, json.dumps(limits))


def drop_replicas(conn):
    """A response copied into another log (a Claude subagent replaying its parent's messages) counts
    once: drop the replayed copy when the original is in the ledger."""
    conn.execute(
        "DELETE FROM entries WHERE replica = 1 AND dedupe_key IS NOT NULL AND EXISTS ("
        "SELECT 1 FROM entries AS original WHERE original.dedupe_key = entries.dedupe_key "
        "AND original.provider = entries.provider AND original.replica = 0 AND original.id <> entries.id)")


def sync(conn, provider="all", codex=None, claude=None, recent_days=None, opencode=None, rescan=False):
    if recent_days is not None and recent_days < 1:
        raise ValueError("Recent days must be positive")
    modified_since = time.time() - recent_days * 86400 if recent_days is not None else 0
    stats = {"files_read": 0, "files_unchanged": 0, "files_deferred": 0,
             "files_outside_window": 0, "ignored_lines": 0, "events_processed": 0, "directories": {},
             "source_errors": []}
    conn.execute("BEGIN IMMEDIATE")
    upgrade = int(setting(conn, "importer_version", "1")) < IMPORTER_VERSION and provider == "all" \
        and recent_days is None
    # A rescan reads every file again, to apply importer improvements to history already imported.
    rescan = rescan or upgrade
    cached = {} if rescan else {row["path"]: row["signature"] for row in conn.execute("SELECT * FROM sources")}
    for source in file_sources(codex, claude):
        if provider not in ("all", source.name):
            continue
        stats["directories"][source.name] = [str(path) for path in source.directories if path.exists()]
        for path in source.files():
            key = f"{source.name}:{path.resolve()}"
            try:
                stat = path.stat()
                if stat.st_mtime < modified_since:
                    stats["files_outside_window"] += 1
                    continue
                before = source_signature(source, path)
                if before == cached.get(key):
                    stats["files_unchanged"] += 1
                    continue
                entries = list(source.read(path, stats))
                if source_signature(source, path) != before:
                    stats["files_deferred"] += 1
                    continue
            except (FileNotFoundError, PermissionError):
                stats["files_deferred"] += 1
                continue
            except (UnreadableSource, sqlite3.Error, ValueError) as error:
                stats["files_deferred"] += 1
                if len(stats["source_errors"]) < 20:
                    stats["source_errors"].append(f"{source.name}: {error}")
                continue
            except Exception as error:  # noqa: BLE001 - one tool's unexpected format must not stop the rest
                if source.name in ("codex", "claude"):
                    raise
                stats["files_deferred"] += 1
                if len(stats["source_errors"]) < 20:
                    stats["source_errors"].append(f"{source.name}: {path.name}: {type(error).__name__}: {error}")
                continue
            store_entries(conn, entries)
            conn.execute("INSERT OR REPLACE INTO sources VALUES (?, ?)", (key, before))
            stats["files_read"] += 1
            stats["events_processed"] += len(entries)
            cached[key] = before
    if provider in ("all", "opencode"):
        sync_opencode(conn, stats, opencode, int(modified_since * 1000))
    drop_replicas(conn)
    if upgrade:
        set_setting(conn, "importer_version", str(IMPORTER_VERSION))
    return stats
